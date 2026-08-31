//
//  ESLinksPipelineFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESLinksPipelineFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDLink.h"
#import "CDLink+CoreDataProperties.h"

@implementation ESLinksPipelineFilter {
    NSSet<NSString *> * _Nullable _edgeFilter;  // lowercased; nil = match all edges
    NSString *_direction;                        // "out" | "in" | "both"
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"links"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _direction = @"both";

        static NSSet<NSString *> *acceptedFlags;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            acceptedFlags = [NSSet setWithArray:@[@"edge", @"edges", @"direction"]];
        });
        for (NSString *flag in stage.flags) {
            if (![acceptedFlags containsObject:flag]) {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:
                                  @"links: unknown flag '--%@'. Accepted: --edge, --edges, --direction.",
                                  flag]}];
                }
                return nil;
            }
        }

        if (stage.positional.count > 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"links: takes no positional args. Usage: ... | links [--edge X] [--direction in|out|both]"}];
            }
            return nil;
        }

        // --edge X (single) and --edges "A,B,C" (multiple, OR-matched). Normalize
        // to a lowercased set so the per-link comparison is one membership check.
        // Edges are typically OR-matched: "show me anything labeled contradicts
        // OR disputes OR corrects OR revises" — the disagreement subgraph.
        NSMutableSet<NSString *> *edges = [NSMutableSet set];
        id edgeVal = stage.flags[@"edge"];
        if ([edgeVal isKindOfClass:NSString.class] && [(NSString *)edgeVal length] > 0) {
            [edges addObject:[(NSString *)edgeVal lowercaseString]];
        }
        id edgesVal = stage.flags[@"edges"];
        if ([edgesVal isKindOfClass:NSString.class]) {
            NSArray<NSString *> *parts = [(NSString *)edgesVal componentsSeparatedByString:@","];
            NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
            for (NSString *p in parts) {
                NSString *trimmed = [[p stringByTrimmingCharactersInSet:ws] lowercaseString];
                if (trimmed.length > 0) [edges addObject:trimmed];
            }
        } else if ([edgesVal isKindOfClass:NSArray.class]) {
            for (id v in (NSArray *)edgesVal) {
                if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
                    [edges addObject:[(NSString *)v lowercaseString]];
                }
            }
        }
        if (edges.count > 0) _edgeFilter = [edges copy];

        id dirVal = stage.flags[@"direction"];
        if ([dirVal isKindOfClass:NSString.class] && [(NSString *)dirVal length] > 0) {
            NSString *d = [(NSString *)dirVal lowercaseString];
            if ([d isEqualToString:@"out"] || [d isEqualToString:@"in"] || [d isEqualToString:@"both"]) {
                _direction = d;
            } else {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:
                                  @"links: --direction must be one of in, out, both (got '%@').", dirVal]}];
                }
                return nil;
            }
        }
    }
    return self;
}

- (BOOL)edgeMatches:(NSString * _Nullable)edge {
    if (!_edgeFilter) return YES;
    if (![edge isKindOfClass:NSString.class] || edge.length == 0) return NO;
    return [_edgeFilter containsObject:edge.lowercaseString];
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    if (!prior) {
        if (errOut) {
            *errOut = [NSError errorWithDomain:@"ESPipelineError" code:4
                                      userInfo:@{NSLocalizedDescriptionKey:
                        @"links: needs an input population (chain after lfind/grep/...). "
                         "For Archive-wide queries, start with `lfind`."}];
        }
        return @[];
    }

    BOOL outDir = ![_direction isEqualToString:@"in"];
    BOOL inDir  = ![_direction isEqualToString:@"out"];

    // Insertion-ordered set so neighbors land in graph-walk order. Downstream
    // sort stages can re-order; for an unsorted pipeline the natural order
    // of "first source's neighbors first" reads more usefully than a hash
    // shuffle.
    NSMutableOrderedSet<NSManagedObjectID *> *result = [NSMutableOrderedSet orderedSet];

    for (NSManagedObjectID *oid in prior) {
        CDMemory *m = (CDMemory *)[ctx existingObjectWithID:oid error:NULL];
        if (!m || [m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) continue;

        if (outDir) {
            for (CDLink *link in m.sourceLinks) {
                if (![self edgeMatches:link.edge]) continue;
                CDMemory *target = link.targetMemory;
                if (target && ![target isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
                    [result addObject:target.objectID];
                }
            }
        }
        if (inDir) {
            for (CDLink *link in m.targetLinks) {
                if (![self edgeMatches:link.edge]) continue;
                CDMemory *source = link.sourceMemory;
                if (source && ![source isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
                    [result addObject:source.objectID];
                }
            }
        }
    }

    return result.array;
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindFilter);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    links — graph traversal: emit the linked neighbors of a population\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    ... | links [--edge NAME | --edges \"A,B,C\"] [--direction in|out|both]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Walks edges outward from every entry in the input population\n"
        @"    and returns the union of connected neighbors as the new\n"
        @"    population. Each neighbor appears once regardless of how many\n"
        @"    input entries link to it. Read-only.\n"
        @"\n"
        @"    --edge NAME       Only follow links whose edge value matches NAME\n"
        @"                      (case-insensitive). Use the disagreement-edge\n"
        @"                      (`contradicts`, `disputes`,\n"
        @"                      `corrects`, `revises`) to surface the questioning\n"
        @"                      subgraph, or any free-form edge name your Archive\n"
        @"                      uses.\n"
        @"    --edges A,B,C     OR-matched set of edge names. Comma-separated,\n"
        @"                      whitespace-tolerant. Combines with --edge if both\n"
        @"                      are passed.\n"
        @"    --direction WHICH out|in|both (default both). out follows edges\n"
        @"                      where the input entry is the source; in follows\n"
        @"                      edges where the input entry is the target. Most\n"
        @"                      callers want both — the graph is read as undirected\n"
        @"                      when the question is \"what's connected.\"\n"
        @"\n"
        @"    Different from archive_links: that tool takes one title and returns\n"
        @"    full link metadata (edge, type, tone, target title) for inspection.\n"
        @"    This filter takes a population and returns a population, so it\n"
        @"    composes with the rest of the pipeline.\n"
        @"\n"
        @"    Output order is graph-walk order (first source's neighbors first,\n"
        @"    then the next source's new neighbors, deduped). Pipe through `sort`\n"
        @"    if a different ordering matters.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    What contradicts entries tagged ES Archive?\n"
        @"        lfind --tag \"ES Archive\" | links --edge contradicts | head 5\n"
        @"\n"
        @"    The full disagreement subgraph (any questioning edge):\n"
        @"        lfind | links --edges \"contradicts,disputes,corrects,revises\"\n"
        @"\n"
        @"    Hubs and their second-degree neighborhood:\n"
        @"        discover --mode hubs | head 10 | links | head 30\n"
        @"\n"
        @"    What incoming references does the canonical Erwinkel entry have?\n"
        @"        grep \"Erwinkel — The Heist\" --title | links --direction in\n"
        @"\n"
        @"SEE ALSO\n"
        @"    archive_link, archive_links, lfind, discover\n";
}

@end
