//
//  ESMemoryDiscoverTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_discover
//  "Analytics: popular, forgotten, lost, hubs, revised, discussed, hot."
//
//  popular   — most accessed memories
//  forgotten — oldest dateAccessed (not nil)
//  lost      — never accessed (dateAccessed is nil)
//  hubs      — most connections (sourceLinks + targetLinks)
//  revised   — most revisions
//  discussed — most marginalia (all-time)
//  hot       — recency-weighted marginalia activity
//

#import "ESMemoryDiscoverTool.h"
#import "CDMemory.h"
#import "CDVector.h"
#import "CDMarginalia.h"
#import "CDMemoryLookup.h"
#import "ESMemoryToolBase.h"
#import "ESVectorEngine.h"

static const NSTimeInterval kHalfLifeDays = 7.0;
static const double kLambda = 0.693147 / kHalfLifeDays;

@implementation ESMemoryDiscoverTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_discover",
        @"description": @"the Archive looking at itself. Modes: popular (most accessed), forgotten (old and unread — buried signal), lost (no tags, no links — orphans waiting for you), hubs (most connected — load-bearing nodes), revised (most edited — living documents), discussed (most commented — thoughts that provoke thinking), hot (active right now — where the conversation is), fiction (invented narratives — story cycles, scenes — surfaced on their own). Every identity mode (all except fiction) excludes type=fiction, so an invented story can't dominate the graph and drown out real entries.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"mode": @{@"type": @"string", @"description": @"popular, forgotten, lost, hubs, revised, discussed, hot, fiction", @"enum": @[@"popular", @"forgotten", @"lost", @"hubs", @"revised", @"discussed", @"hot", @"fiction"]},
                @"limit": @{@"description": @"Default: 20.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"focus": @{
                    @"type": @"string",
                    @"description": @"Override temporal focus for this call only. Does not persist.",
                    @"enum": @[@"day", @"week", @"month", @"none"]
                },
                @"include_summary": @{@"description": @"If true, include each entry's summary in results — lets you skim a discover mode without N archive_read calls. Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]}
            },
            @"required": @[@"mode"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *mode = arguments[@"mode"];
    NSUInteger limit = [ESMemoryToolBase unsignedIntegerFromArgs:arguments key:@"limit" default:20];
    if (limit == 0) limit = 20;

    // Per-call focus override — validated, reported in response
    NSString *focusOverride = arguments[@"focus"];
    if (focusOverride && ![[ESVectorEngine decayLevels] containsObject:focusOverride]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Invalid focus: '%@'. Valid: day, week, month, none.", focusOverride]}];
        }
        return nil;
    }

    BOOL includeSummary = [ESMemoryToolBase boolFromArgs:arguments
                                                     key:@"include_summary"
                                                 default:NO];

    NSManagedObjectContext *ctx = store.viewContext;

    NSDictionary *result = nil;
    if ([mode isEqualToString:@"popular"]) {
        result = [self popularWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"forgotten"]) {
        result = [self forgottenWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"lost"]) {
        result = [self lostWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"hubs"]) {
        result = [self hubsWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"revised"]) {
        result = [self revisedWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"discussed"]) {
        result = [self discussedWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"hot"]) {
        result = [self hotWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else if ([mode isEqualToString:@"fiction"]) {
        result = [self fictionWithLimit:limit scopeAuthor:scope.author context:ctx includeSummary:includeSummary];
    } else {
        return @{@"status": @"unknown_mode"};
    }

    // Append effective focus to response
    NSString *effectiveDecay = focusOverride ?: [ESVectorEngine defaultDecayLevel];
    NSMutableDictionary *enriched = [result mutableCopy];
    enriched[@"focus"] = [ESVectorEngine decayLevelDescriptions][effectiveDecay] ?: effectiveDecay;
    return enriched;
}

+ (NSDictionary *)popularWithLimit:(NSUInteger)limit
                           scopeAuthor:(NSString *)scopeAuthor
                           context:(NSManagedObjectContext *)ctx
                    includeSummary:(BOOL)includeSummary {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [ESMemoryToolBase identityScopeForAuthor:scopeAuthor];
    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"accessCount" ascending:NO]];
    fetch.fetchLimit = limit;

    NSArray<CDMemory *> *memories = [ctx executeFetchRequest:fetch error:nil];
    return [self formatResults:memories mode:@"popular" includeSummary:includeSummary];
}

+ (NSDictionary *)forgottenWithLimit:(NSUInteger)limit
                             scopeAuthor:(NSString *)scopeAuthor
                             context:(NSManagedObjectContext *)ctx
                      includeSummary:(BOOL)includeSummary {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase identityScopeForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"dateAccessed != nil"]]];
    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateAccessed" ascending:YES]];
    fetch.fetchLimit = limit;

    NSArray<CDMemory *> *memories = [ctx executeFetchRequest:fetch error:nil];
    return [self formatResults:memories mode:@"forgotten" includeSummary:includeSummary];
}

+ (NSDictionary *)lostWithLimit:(NSUInteger)limit
                        scopeAuthor:(NSString *)scopeAuthor
                        context:(NSManagedObjectContext *)ctx
                 includeSummary:(BOOL)includeSummary {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase identityScopeForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"dateAccessed == nil"]]];
    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES]];
    fetch.fetchLimit = limit;

    NSArray<CDMemory *> *memories = [ctx executeFetchRequest:fetch error:nil];
    return [self formatResults:memories mode:@"lost" includeSummary:includeSummary];
}

+ (NSDictionary *)hubsWithLimit:(NSUInteger)limit
                        scopeAuthor:(NSString *)scopeAuthor
                        context:(NSManagedObjectContext *)ctx
                 includeSummary:(BOOL)includeSummary {
    // Fetch all head memories and sort by connection count in-memory
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [ESMemoryToolBase identityScopeForAuthor:scopeAuthor];
    fetch.relationshipKeyPathsForPrefetching = @[@"sourceLinks", @"targetLinks"];

    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:nil];
    NSArray<CDMemory *> *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        NSUInteger countA = a.sourceLinks.count + a.targetLinks.count;
        NSUInteger countB = b.sourceLinks.count + b.targetLinks.count;
        return countB > countA ? NSOrderedDescending : (countB < countA ? NSOrderedAscending : NSOrderedSame);
    }];

    NSArray *limited = sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
    return [self formatResults:limited mode:@"hubs" includeSummary:includeSummary];
}

+ (NSDictionary *)revisedWithLimit:(NSUInteger)limit
                           scopeAuthor:(NSString *)scopeAuthor
                           context:(NSManagedObjectContext *)ctx
                    includeSummary:(BOOL)includeSummary {
    // Fetch all head memories and sort by revision count in-memory
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase identityScopeForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"revisions.@count > 0"]]];
    fetch.relationshipKeyPathsForPrefetching = @[@"revisions"];

    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:nil];
    NSArray<CDMemory *> *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        return b.revisions.count > a.revisions.count ? NSOrderedDescending
             : (b.revisions.count < a.revisions.count ? NSOrderedAscending : NSOrderedSame);
    }];

    NSArray *limited = sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
    return [self formatResults:limited mode:@"revised" includeSummary:includeSummary];
}

+ (NSDictionary *)discussedWithLimit:(NSUInteger)limit
                             scopeAuthor:(NSString *)scopeAuthor
                             context:(NSManagedObjectContext *)ctx
                      includeSummary:(BOOL)includeSummary {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase identityScopeForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"marginalia.@count > 0"]]];
    fetch.relationshipKeyPathsForPrefetching = @[@"marginalia"];

    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:nil];
    NSArray<CDMemory *> *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        return b.marginalia.count > a.marginalia.count ? NSOrderedDescending
             : (b.marginalia.count < a.marginalia.count ? NSOrderedAscending : NSOrderedSame);
    }];

    NSArray *limited = sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
    return [self formatResults:limited mode:@"discussed" includeSummary:includeSummary];
}

+ (NSDictionary *)hotWithLimit:(NSUInteger)limit
                       scopeAuthor:(NSString *)scopeAuthor
                       context:(NSManagedObjectContext *)ctx
                includeSummary:(BOOL)includeSummary {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase identityScopeForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"marginalia.@count > 0"]]];
    fetch.relationshipKeyPathsForPrefetching = @[@"marginalia"];

    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:nil];
    NSDate *now = [NSDate now];

    // Compute heat scores and sort
    NSMutableArray<NSDictionary *> *scored = [NSMutableArray arrayWithCapacity:all.count];
    for (CDMemory *m in all) {
        double heat = 0.0;
        for (CDMarginalia *note in m.marginalia) {
            NSTimeInterval ageDays = [now timeIntervalSinceDate:note.dateCreated] / 86400.0;
            if (ageDays < 0) ageDays = 0;
            heat += exp(-kLambda * ageDays);
        }
        [scored addObject:@{@"memory": m, @"heat": @(heat)}];
    }

    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double heatA = [a[@"heat"] doubleValue];
        double heatB = [b[@"heat"] doubleValue];
        return heatB > heatA ? NSOrderedDescending : (heatB < heatA ? NSOrderedAscending : NSOrderedSame);
    }];

    NSUInteger count = MIN(limit, scored.count);
    NSMutableArray<CDMemory *> *topMemories = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [topMemories addObject:scored[i][@"memory"]];
    }
    return [self formatResults:topMemories mode:@"hot" includeSummary:includeSummary];
}

+ (NSDictionary *)fictionWithLimit:(NSUInteger)limit
                       scopeAuthor:(NSString *)scopeAuthor
                           context:(NSManagedObjectContext *)ctx
                    includeSummary:(BOOL)includeSummary {
    // The fiction layer — invented narratives (story cycles, scenes). Kept out
    // of every identity-bearing mode; surfaced here on its own, most-connected
    // first so a cycle's root/index entries lead.
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [ESMemoryToolBase scopePredicateForAuthor:scopeAuthor],
        [NSPredicate predicateWithFormat:@"type ==[c] %@", @"fiction"]]];
    fetch.relationshipKeyPathsForPrefetching = @[@"sourceLinks", @"targetLinks"];

    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:nil];
    NSArray<CDMemory *> *sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        NSUInteger countA = a.sourceLinks.count + a.targetLinks.count;
        NSUInteger countB = b.sourceLinks.count + b.targetLinks.count;
        return countB > countA ? NSOrderedDescending : (countB < countA ? NSOrderedAscending : NSOrderedSame);
    }];
    NSArray *limited = sorted.count > limit ? [sorted subarrayWithRange:NSMakeRange(0, limit)] : sorted;
    return [self formatResults:limited mode:@"fiction" includeSummary:includeSummary];
}

+ (NSDictionary *)formatResults:(NSArray<CDMemory *> *)memories
                           mode:(NSString *)mode
                 includeSummary:(BOOL)includeSummary {
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSMutableArray *results = [NSMutableArray array];
    NSMutableArray *objectIDs = [NSMutableArray arrayWithCapacity:memories.count];
    NSMutableArray *discoverScores = [NSMutableArray arrayWithCapacity:memories.count];

    for (NSUInteger i = 0; i < memories.count; i++) {
        CDMemory *m = memories[i];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"title"] = m.title ?: @"Untitled";
        entry[@"accessCount"] = @(m.accessCount);
        entry[@"connectionCount"] = @(m.sourceLinks.count + m.targetLinks.count);
        entry[@"lastAccessed"] = m.dateAccessed ? [df stringFromDate:m.dateAccessed] : @"never";
        if (includeSummary) {
            entry[@"summary"] = m.summary ?: @"";
        }
        [results addObject:entry];

        [objectIDs addObject:m.objectID];
        CGFloat score = 1.0 - (CGFloat)i / fmax(1, memories.count) * 0.7;
        [discoverScores addObject:@(score)];
    }

    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeDiscover
                                   objectIDs:objectIDs
                                      scores:discoverScores
                                    originID:nil];

    return @{
        @"mode": mode,
        @"count": @(results.count),
        @"results": results
    };
}

@end
