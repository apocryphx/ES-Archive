//
//  ESPipelineExecutor.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESPipelineExecutor.h"
#import "ESPipelineFilter.h"
#import "ESPipelineDiagnostic.h"
#import "ESMemoryToolBase.h"
#import "CDMemory.h"
#import "CDMemory+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import <objc/runtime.h>

// The individual filter class headers are imported here ONLY to ensure
// each filter's .o is linked into the binary — we don't reference the
// classes by name in code anymore. The filter registry below discovers
// them dynamically via objc_copyClassList + protocol conformance.
//
// Adding a new filter class:
//   1. Create ESFooFilter.{h,m} in Pipeline/Filters/
//   2. Conform to ESPipelineFilter; implement the required methods
//   3. Add the import below (one line)
//   4. The class auto-registers; appears in man index; dispatchable.
#import "ESLfindFilter.h"
#import "ESW2vgrepFilter.h"
#import "ESGrepFilter.h"
#import "ESDiscoverFilter.h"
#import "ESSortFilter.h"
#import "ESHeadFilter.h"
#import "ESTailFilter.h"
#import "ESCatFilter.h"
#import "ESWcFilter.h"
#import "ESManFilter.h"
#import "ESArcFilter.h"

#pragma mark - Filter registry

// Discover filter classes dynamically via objc_copyClassList. Any class
// conforming to ESPipelineFilter — anywhere in the binary — gets registered
// and dispatchable by its commandName. No central array to update; adding
// a filter is adding a class file (plus a one-line import above to ensure
// it's linked).
//
// The dispatch_once cache amortizes the runtime traversal — subsequent calls
// are O(1) dictionary lookups.
static NSDictionary<NSString *, Class> *FilterRegistry(void) {
    static NSDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) {
            registry = @{};
            return;
        }

        Protocol *protocol = @protocol(ESPipelineFilter);
        NSMutableDictionary<NSString *, Class> *map = [NSMutableDictionary dictionary];
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            if (!class_conformsToProtocol(cls, protocol)) continue;

            // commandName is required (@required class method). Defensively
            // skip if it's missing or returns nil.
            if (![cls respondsToSelector:@selector(commandName)]) continue;
            NSString *name = [cls performSelector:@selector(commandName)];
            if (![name isKindOfClass:NSString.class] || name.length == 0) continue;

            // First-registration wins on collision (shouldn't happen — names
            // should be unique by convention).
            if (!map[name]) map[name] = cls;
        }
        free(classes);
        registry = [map copy];
    });
    return registry;
}

Class _Nullable ESPipelineFilterClassForCommand(NSString *commandName) {
    return FilterRegistry()[commandName];
}

NSArray<Class> *ESPipelineRegisteredFilterClasses(void) {
    return [FilterRegistry().allValues sortedArrayUsingComparator:^NSComparisonResult(Class a, Class b) {
        NSString *na = [a performSelector:@selector(commandName)];
        NSString *nb = [b performSelector:@selector(commandName)];
        return [na compare:nb];
    }];
}

#pragma mark - Default rendering

// Subset a score map to only the IDs in `survivors`. Used when a filter
// trims the population without introducing new scores — we want to drop
// entries for IDs that no longer exist downstream rather than carry stale
// data.
static NSDictionary<NSManagedObjectID *, NSNumber *> *
SubsetScoreMap(NSDictionary<NSManagedObjectID *, NSNumber *> *map,
                NSArray<NSManagedObjectID *> *survivors) {
    if (!map || survivors.count == 0) return nil;
    NSMutableDictionary<NSManagedObjectID *, NSNumber *> *out =
        [NSMutableDictionary dictionaryWithCapacity:survivors.count];
    for (NSManagedObjectID *oid in survivors) {
        NSNumber *s = map[oid];
        if (s) out[oid] = s;
    }
    return [out copy];
}

// Render the final population as the response shape Claude reads. Phase 1
// returns title + summary (when available). Filters that need richer output
// (cat returning bodies) override by setting their own response shape.
//
// `scoreMap` is optional — when a filter advertises per-result scores via
// the `lastScoreMap` protocol method (w2vgrep is the canonical case), the
// executor passes them here and we inline the score as a "[N.NNN] " prefix
// on the title field. Visual adjacency matters: a reader who has just
// resolved the title shouldn't have to make a second field lookup to learn
// how confident the match is. Three decimal places — compact, unambiguous,
// consistent with the score scale documented in the man pages. The score
// is NOT also emitted as a separate field; the prefix is the surface.
//
// `includeDateCreated` is set by the executor when any filter in the
// pipeline declares +requiresDateContext (arc is the canonical case — a
// session-cluster is unintelligible without timestamps). When YES, the
// row carries an ISO-8601 dateCreated. The default is NO; non-temporal
// pipelines stay quiet about dates.
static NSArray<NSDictionary *> *RenderPopulation(NSArray<NSManagedObjectID *> *ids,
                                                  NSManagedObjectContext *ctx,
                                                  NSDictionary<NSManagedObjectID *, NSNumber *> * _Nullable scoreMap,
                                                  BOOL includeDateCreated) {
    NSISO8601DateFormatter *df = includeDateCreated ? [CDMemoryLookup sharedFormatter] : nil;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:ids.count];
    for (NSManagedObjectID *oid in ids) {
        NSError *err = nil;
        NSManagedObject *obj = [ctx existingObjectWithID:oid error:&err];
        if (err || ![obj isKindOfClass:CDMemory.class]) continue;
        CDMemory *m = (CDMemory *)obj;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        NSString *titleStr = m.title ?: @"Untitled";
        NSNumber *score = scoreMap[oid];
        if (score) {
            titleStr = [NSString stringWithFormat:@"[%.3f] %@", score.doubleValue, titleStr];
        }
        row[@"title"] = titleStr;
        if (includeDateCreated && m.dateCreated) {
            row[@"dateCreated"] = [df stringFromDate:m.dateCreated];
        }
        if (m.summary.length > 0) row[@"summary"] = m.summary;
        if (m.uuid) row[@"uuid"] = m.uuid.UUIDString;
        [out addObject:row];
    }
    return out;
}

#pragma mark - Phase 2 fusion helpers

// Width to pad command spellings to before "→" — matches ESPipelineDiagnostic.
static const NSUInteger kDiagPadWidth = 40;

static NSString *PadSpelling(NSString *s) {
    if (s.length >= kDiagPadWidth) return [s stringByAppendingString:@" "];
    NSMutableString *padded = [s mutableCopy];
    while (padded.length < kDiagPadWidth) [padded appendString:@" "];
    return padded;
}

// True if the filter contributes anything to a unified fetch (predicate,
// sort, or limit). These filters can join a fusion run.
static BOOL IsFusableContinuation(id<ESPipelineFilter> filter) {
    return [filter respondsToSelector:@selector(predicateContributionWithContext:)]
        || [filter respondsToSelector:@selector(sortDescriptorContribution)]
        || [filter respondsToSelector:@selector(fetchLimitContribution)];
}

// Detect a fusion run starting at startIdx. A fusion run requires:
//   1. ≥2 contiguous fusable filters
//   2. At least one filter contributes a non-nil predicate, OR `prior` is
//      non-nil (in which case the executor implicitly adds SELF IN prior
//      as the predicate, bounding the fetch). This relaxation lets pipelines
//      like `w2vgrep | sort popular | head 5` fuse the trailing two stages.
// Returns NSMakeRange(NSNotFound, 0) if no fusion is possible.
static NSRange DetectFusionRun(NSArray<id<ESPipelineFilter>> *filters,
                                NSUInteger startIdx,
                                NSArray<NSManagedObjectID *> * _Nullable prior,
                                NSManagedObjectContext *ctx) {
    NSUInteger end = startIdx;
    BOOL hasPredicate = (prior != nil);  // SELF IN prior counts as predicate

    while (end < filters.count) {
        id<ESPipelineFilter> f = filters[end];
        if (!IsFusableContinuation(f)) break;

        if ([f respondsToSelector:@selector(predicateContributionWithContext:)]) {
            NSPredicate *p = [f predicateContributionWithContext:ctx];
            if (p) hasPredicate = YES;
        }
        end++;
    }

    NSUInteger length = end - startIdx;
    if (length < 2 || !hasPredicate) {
        return NSMakeRange(NSNotFound, 0);
    }
    return NSMakeRange(startIdx, length);
}

// Execute a fused run as a single NSFetchRequest. Combines predicates with
// AND, takes the LAST sort descriptor contribution (last-wins), and the
// minimum of all limit contributions.
static NSArray<NSManagedObjectID *> *ExecuteFusedRun(NSArray<id<ESPipelineFilter>> *filters,
                                                      NSRange range,
                                                      NSArray<NSManagedObjectID *> * _Nullable prior,
                                                      NSManagedObjectContext *ctx,
                                                      NSError **errOut) {
    NSMutableArray<NSPredicate *> *predClauses = [NSMutableArray array];
    NSArray<NSSortDescriptor *> *sortDescriptors = nil;
    NSNumber *fetchLimit = nil;

    for (NSUInteger i = range.location; i < range.location + range.length; i++) {
        id<ESPipelineFilter> pipelineFilter = filters[i];
        if ([pipelineFilter respondsToSelector:@selector(predicateContributionWithContext:)]) {
            NSPredicate *predicate = [pipelineFilter predicateContributionWithContext:ctx];
            if (predicate) [predClauses addObject:predicate];
        }
        if ([pipelineFilter respondsToSelector:@selector(sortDescriptorContribution)]) {
            NSArray<NSSortDescriptor *> *sortDescriptor = [pipelineFilter sortDescriptorContribution];
            if (sortDescriptor) sortDescriptors = sortDescriptor;  // last wins
        }
        if ([pipelineFilter respondsToSelector:@selector(fetchLimitContribution)]) {
            NSNumber *limit = [pipelineFilter fetchLimitContribution];
            if (limit != nil) {
                fetchLimit = (fetchLimit == nil)
                    ? limit
                    : @(MIN(fetchLimit.unsignedIntegerValue, limit.unsignedIntegerValue));
            }
        }
    }

    if (prior) {
        [predClauses addObject:[NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]]];
    }

    NSFetchRequest *fr = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fr.includesSubentities = NO;
    fr.resultType = NSManagedObjectIDResultType;
    if (predClauses.count == 1) {
        fr.predicate = predClauses.firstObject;
    } else if (predClauses.count > 1) {
        fr.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predClauses];
    }
    fr.sortDescriptors = sortDescriptors;
    if (fetchLimit) fr.fetchLimit = fetchLimit.unsignedIntegerValue;

    NSError *err = nil;
    NSArray<NSManagedObjectID *> *ids = [ctx executeFetchRequest:fr error:&err];
    if (err) {
        if (errOut) *errOut = err;
        return @[];
    }
    return ids ?: @[];
}

// Build per-stage diagnostic lines for a fusion run. All but the last show
// "→ fused" (no count, since intermediate counts weren't computed). The last
// shows the actual count plus an annotation explaining the fusion.
static void EmitFusionDiagnostic(NSArray<id<ESPipelineFilter>> *filters,
                                  NSArray<ESPipelineStage *> *parsedStages,
                                  NSRange range,
                                  NSUInteger finalCount,
                                  NSMutableArray<NSString *> *diagLines) {
    for (NSUInteger i = range.location; i < range.location + range.length; i++) {
        ESPipelineStage *stage = parsedStages[i];
        NSString *spelling = ESPipelineStageSpelling(stage.name, stage.positional, stage.flags);
        NSString *prefixed = (i == 0 && diagLines.count == 0)
            ? spelling
            : [@"| " stringByAppendingString:spelling];
        NSString *padded = PadSpelling(prefixed);

        BOOL isLastInRun = (i == range.location + range.length - 1);
        if (!isLastInRun) {
            [diagLines addObject:[padded stringByAppendingString:@"→ fused"]];
        } else {
            NSString *annotation = [NSString stringWithFormat:
                @"  (%lu stages fused into 1 NSFetchRequest)", (unsigned long)range.length];
            [diagLines addObject:[NSString stringWithFormat:@"%@→ %lu hits%@",
                padded, (unsigned long)finalCount, annotation]];
        }
    }
}

#pragma mark - Execute

NSDictionary *ESPipelineExecute(NSArray<NSDictionary *> *stages,
                                 NSManagedObjectContext *ctx,
                                 NSString *scopeAuthor) {
    if (![stages isKindOfClass:NSArray.class] || stages.count == 0) {
        return @{
            @"error":   @"empty_pipeline",
            @"message": @"No stages. Try 'man' to see available commands.",
        };
    }

    // Compute the persona-scoped population once. This both (a) seeds `prior`
    // so every filter is bounded to the persona's own memories, and (b) serves
    // as the backstop the final population is intersected against — so even a
    // filter that ignored `prior` cannot leak another persona's memory.
    NSSet<NSManagedObjectID *> *scopeSet = nil;
    {
        NSFetchRequest *sfetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        sfetch.includesSubentities = NO;
        sfetch.resultType = NSManagedObjectIDResultType;
        sfetch.predicate = [ESMemoryToolBase scopePredicateForAuthor:scopeAuthor];
        NSArray<NSManagedObjectID *> *sids = [ctx executeFetchRequest:sfetch error:nil] ?: @[];
        scopeSet = [NSSet setWithArray:sids];
    }

    // Pass 1: parse and instantiate every filter. Surfaces malformed-stage,
    // unknown-command, and invalid-argument errors before any work runs.
    NSMutableArray<ESPipelineStage *> *parsedStages =
        [NSMutableArray arrayWithCapacity:stages.count];
    NSMutableArray<id<ESPipelineFilter>> *filters =
        [NSMutableArray arrayWithCapacity:stages.count];

    for (NSUInteger idx = 0; idx < stages.count; idx++) {
        NSDictionary *stageDict = stages[idx];
        ESPipelineStage *stage = [ESPipelineStage stageFromDictionary:stageDict];
        if (!stage) {
            return @{
                @"error":   @"malformed_stage",
                @"message": [NSString stringWithFormat:
                    @"stage %lu is not a valid {name, positional, flags} dict",
                    (unsigned long)idx],
            };
        }
        Class filterClass = ESPipelineFilterClassForCommand(stage.name);
        if (!filterClass) {
            return @{
                @"error":   @"unknown_command",
                @"message": [NSString stringWithFormat:
                    @"unknown command: %@. Try 'man' to see available commands.",
                    stage.name],
            };
        }
        // A persona may only scope to its own author. An explicit --author that
        // differs from the connection's scope is an attempt to read across
        // personas — reject loudly (the seeded scope would also make it return
        // nothing, but a clear error beats silent emptiness).
        id flagAuthor = stage.flags[@"author"];
        if ([flagAuthor isKindOfClass:NSString.class] && [(NSString *)flagAuthor length] > 0 &&
            ![(NSString *)flagAuthor isEqualToString:scopeAuthor]) {
            return @{
                @"error":   @"scope_violation",
                @"message": [NSString stringWithFormat:
                    @"--author '%@' is outside this connection's scope.", flagAuthor],
            };
        }
        NSError *initErr = nil;
        id<ESPipelineFilter> filter = [(id)[filterClass alloc] initWithStage:stage error:&initErr];
        if (!filter) {
            return @{
                @"error":   @"invalid_arguments",
                @"message": initErr.localizedDescription ?:
                    [NSString stringWithFormat:@"%@: invalid arguments", stage.name],
            };
        }
        [parsedStages addObject:stage];
        [filters addObject:filter];
    }

    // Pass 2: execute, fusing contiguous fusable runs into single fetches.
    NSMutableArray<NSString *> *diagLines = [NSMutableArray arrayWithCapacity:stages.count];
    // Seed the population with the persona's scoped memories (never nil), so
    // every stage is bounded to the persona from the first filter onward.
    NSArray<NSManagedObjectID *> *prior = scopeSet.allObjects;
    // Score map threaded across stages. Populated by filters that implement
    // -lastScoreMap (w2vgrep). Filters that only trim the population (head,
    // sort, etc.) inherit the prior map filtered to surviving IDs, so a
    // pipeline like `w2vgrep "..." | head 5` still surfaces scores in the
    // final silhouette.
    NSDictionary<NSManagedObjectID *, NSNumber *> *currentScoreMap = nil;
    NSUInteger i = 0;

    while (i < filters.count) {
        // Try fusion first. If a multi-stage fusable run starts here AND
        // contains at least one predicate (or prior is non-nil, supplying
        // an implicit SELF IN prior predicate), execute as one NSFetchRequest.
        NSRange fusionRange = DetectFusionRun(filters, i, prior, ctx);
        if (fusionRange.location != NSNotFound) {
            NSError *fuseErr = nil;
            NSArray<NSManagedObjectID *> *result =
                ExecuteFusedRun(filters, fusionRange, prior, ctx, &fuseErr);
            if (fuseErr) {
                return @{
                    @"error":    @"fusion_failed",
                    @"message":  fuseErr.localizedDescription ?: @"fused fetch failed",
                    @"pipeline": [diagLines componentsJoinedByString:@"\n"],
                };
            }
            EmitFusionDiagnostic(filters, parsedStages, fusionRange, result.count, diagLines);
            prior = result;
            // Fused runs only trim — they don't introduce scores. Carry the
            // current score map forward, narrowed to surviving IDs.
            currentScoreMap = SubsetScoreMap(currentScoreMap, result);
            i = fusionRange.location + fusionRange.length;
            continue;
        }

        // Sequential: instantiate, apply, emit diagnostic.
        ESPipelineStage *stage = parsedStages[i];
        id<ESPipelineFilter> filter = filters[i];
        Class filterClass = [(NSObject *)filter class];

        NSError *applyErr = nil;
        NSArray<NSManagedObjectID *> *result = [filter applyToInput:prior context:ctx error:&applyErr];
        if (applyErr) {
            return @{
                @"error":    @"apply_failed",
                @"message":  applyErr.localizedDescription ?: [NSString stringWithFormat:@"%@ failed", stage.name],
                @"pipeline": [diagLines componentsJoinedByString:@"\n"],
            };
        }

        BOOL isFirst = (diagLines.count == 0);
        BOOL isLast = (i == filters.count - 1);

        BOOL suppress = NO;
        if ([filterClass respondsToSelector:@selector(suppressesPipelineDiagnostic)]) {
            suppress = [filterClass suppressesPipelineDiagnostic];
        }
        if (!suppress) {
            NSString *line = [filter diagnosticLineWithPrior:prior result:result isFirst:isFirst];
            [diagLines addObject:line];
        }

        prior = result;

        // Score-map propagation: if this filter advertises scores, take them
        // (replacing whatever prior stages produced). Otherwise narrow the
        // existing map to surviving IDs.
        if ([filter respondsToSelector:@selector(lastScoreMap)]) {
            NSDictionary<NSManagedObjectID *, NSNumber *> *m = [filter lastScoreMap];
            if (m) currentScoreMap = m;
            else   currentScoreMap = SubsetScoreMap(currentScoreMap, result);
        } else {
            currentScoreMap = SubsetScoreMap(currentScoreMap, result);
        }

        // Terminal stages produce their own response shape and short-circuit
        // the default rendering. Only honored on the last stage of the pipeline.
        if (isLast && [filter respondsToSelector:@selector(terminalResponseWithPrior:context:error:)]) {
            // Backstop: a terminal (cat/wc/...) must only ever see in-scope IDs,
            // even if some upstream filter ignored `prior`.
            NSMutableArray<NSManagedObjectID *> *scopedResult = [NSMutableArray array];
            for (NSManagedObjectID *oid in result) {
                if ([scopeSet containsObject:oid]) [scopedResult addObject:oid];
            }
            result = scopedResult;
            NSError *termErr = nil;
            NSDictionary *termResponse = [filter terminalResponseWithPrior:result
                                                                    context:ctx
                                                                      error:&termErr];
            if (termErr) {
                NSMutableDictionary *err = [NSMutableDictionary dictionary];
                err[@"error"]    = @"terminal_failed";
                err[@"message"]  = termErr.localizedDescription ?: [NSString stringWithFormat:@"%@ failed", stage.name];
                if (diagLines.count > 0) {
                    err[@"pipeline"] = [diagLines componentsJoinedByString:@"\n"];
                }
                return err;
            }
            NSMutableDictionary *response = [termResponse mutableCopy] ?: [NSMutableDictionary dictionary];
            // Only include the pipeline field when there's something to show.
            if (diagLines.count > 0) {
                response[@"pipeline"] = [diagLines componentsJoinedByString:@"\n"];
            }
            return response;
        }

        i++;
    }

    // Check whether any filter in the pipeline asked for date context
    // (arc is the canonical case). Single scan; cheap. If any does, the
    // standard render emits dateCreated per row.
    BOOL includeDateCreated = NO;
    for (id<ESPipelineFilter> filter in filters) {
        Class fc = [(NSObject *)filter class];
        if ([fc respondsToSelector:@selector(requiresDateContext)] &&
            [fc requiresDateContext]) {
            includeDateCreated = YES;
            break;
        }
    }

    // Backstop: intersect the final population with the persona scope so a
    // filter that ignored `prior` (e.g. a generator stage) cannot leak another
    // persona's memory into the rendered output.
    NSMutableArray<NSManagedObjectID *> *scopedFinal = [NSMutableArray array];
    for (NSManagedObjectID *oid in (prior ?: @[])) {
        if ([scopeSet containsObject:oid]) [scopedFinal addObject:oid];
    }
    prior = scopedFinal;

    NSMutableDictionary *finalResult = [NSMutableDictionary dictionary];
    finalResult[@"results"] = RenderPopulation(prior ?: @[], ctx, currentScoreMap, includeDateCreated);
    finalResult[@"count"]   = @((prior ?: @[]).count);
    if (diagLines.count > 0) {
        finalResult[@"pipeline"] = [diagLines componentsJoinedByString:@"\n"];
    }
    return finalResult;
}
