//
//  ESMemorySearchTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_search
//  "Semantic vector search. Use for concepts and themes, not proper nouns."
//

#import "ESMemorySearchTool.h"
#import "ESVectorEngine.h"
#import "ESVectorSearchResult.h"
#import "CDMemory.h"
#import "CDMemory+CoreDataProperties.h"
#import "CDVector.h"
#import "CDTag.h"
#import "CDTag.h"
#import "ESMemoryToolBase.h"

@implementation ESMemorySearchTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_search",
        @"description": @"Semantic vector search. Think in concepts, not keywords. Start here when something feels familiar. Previous sessions left breadcrumbs. Not for proper nouns.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"query": @{
                    @"type": @"string",
                    @"description": @"Natural language query."
                },
                @"limit": @{
                    @"description": @"Maximum number of results. Default: 10.",
                    @"oneOf": @[
                        @{ @"type": @"integer", @"minimum": @1, @"maximum": @50 },
                        @{ @"type": @"string" }
                    ]
                },
                @"focus": @{
                    @"type": @"string",
                    @"description": @"Override temporal focus for this call only. Does not persist.",
                    @"enum": @[@"day", @"week", @"month", @"none"]
                },
                @"tags": @{
                    @"type": @"array",
                    @"description": @"Restrict ranking to entries carrying ANY of these tags (OR semantics, case-insensitive). Use this when a proper noun is load-bearing — e.g. 'review entries about Illucida' → tags:[\"Illucida\"]. Leave absent for unfiltered search.",
                    @"items": @{@"type": @"string"}
                }
            },
            @"required": @[@"query"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *query = arguments[@"query"];
    if (!query || ![query isKindOfClass:NSString.class] || query.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: @"'query' is required"}];
        }
        return nil;
    }

    NSUInteger limit = [ESMemoryToolBase unsignedIntegerFromArgs:arguments key:@"limit" default:10];
    if (limit == 0) limit = 10;

    // Per-call focus override (nil = use global)
    NSString *focusOverride = arguments[@"focus"];
    if (focusOverride && ![[ESVectorEngine decayLevels] containsObject:focusOverride]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Invalid focus: '%@'. Valid: day, week, month, none.", focusOverride]}];
        }
        return nil;
    }

    // Tag filter (optional). Resolve tag names → set of CDVector objectIDs.
    // Empty / absent → no filter. Present but unresolved → empty result with note.
    NSArray *rawTags = [ESMemoryToolBase arrayFromArgs:arguments key:@"tags"];
    NSMutableArray<NSString *> *tagNames = nil;
    if (rawTags) {
        tagNames = [NSMutableArray array];
        for (id name in rawTags) {
            if ([name isKindOfClass:NSString.class] && [(NSString *)name length] > 0) {
                [tagNames addObject:(NSString *)name];
            }
        }
        if (tagNames.count == 0) tagNames = nil;
    }

    // Persona scope is ALWAYS applied: vector search is constrained to the
    // connecting persona's own memories (their "similar" stays their own).
    // The set is the intersection of (author == me) AND (tags), so the global
    // unscoped search path no longer exists.
    NSSet<NSManagedObjectID *> *allowedVectorIDs = nil;
    {
        NSManagedObjectContext *ctx = store.viewContext;

        NSMutableArray<NSPredicate *> *preds = [NSMutableArray array];
        [preds addObject:[ESMemoryToolBase scopePredicateForAuthor:scope.author]];

        if (tagNames) {
            // Resolve each name case-insensitively via findByName: (==[cd]),
            // collect CDTag objects, then constrain by tag identity. NSPredicate's
            // [cd] modifier does not apply element-wise to IN, so we resolve first.
            NSMutableArray<CDTag *> *tags = [NSMutableArray array];
            for (NSString *name in tagNames) {
                CDTag *tag = [CDTag findByName:name context:ctx];
                if (tag) [tags addObject:tag];
            }
            if (tags.count == 0) {
                return @{
                    @"query": query,
                    @"count": @0,
                    @"results": @[],
                    @"tags": tagNames,
                    @"note": @"No entries carry any of the requested tags."
                };
            }
            [preds addObject:[NSPredicate predicateWithFormat:@"ANY tags IN %@", tags]];
        }

        NSFetchRequest *fetch = [CDMemory fetchRequest];
        fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:preds];
        fetch.includesSubentities = NO;
        fetch.relationshipKeyPathsForPrefetching = @[@"vector"];

        NSError *fetchError = nil;
        NSArray<CDMemory *> *matches = [ctx executeFetchRequest:fetch error:&fetchError];
        if (fetchError) {
            if (error) *error = fetchError;
            return nil;
        }

        NSMutableSet<NSManagedObjectID *> *ids = [NSMutableSet set];
        for (CDMemory *m in matches) {
            CDVector *v = [m vectorForActiveEmbedder];
            if (v) [ids addObject:v.objectID];
        }

        if (ids.count == 0) {
            NSMutableDictionary *empty = [@{
                @"query": query,
                @"count": @0,
                @"results": @[],
                @"note": tagNames ? @"No entries in your scope carry any of the requested tags."
                                  : @"No entries in your scope yet."
            } mutableCopy];
            if (tagNames) empty[@"tags"] = tagNames;
            return empty;
        }
        allowedVectorIDs = ids;
    }

    NSArray<ESVectorSearchResult *> *results = [[ESVectorEngine shared] searchWithQuery:query
                                                                                  limit:limit
                                                                             decayLevel:focusOverride
                                                                       allowedVectorIDs:allowedVectorIDs];

    NSMutableArray *output = [NSMutableArray arrayWithCapacity:results.count];
    NSMutableArray *rankedIDs = [NSMutableArray arrayWithCapacity:results.count];
    NSMutableArray *searchScores = [NSMutableArray arrayWithCapacity:results.count];
    for (ESVectorSearchResult *r in results) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"title"] = r.memory.title ?: @"Untitled";
        // Surface the raw cosine directly. The retired NLContextualEmbedding
        // compressed cosines into ~0.7–0.95 and needed rescaling to be readable;
        // EmbeddingGemma already spreads the distribution wide (unrelated text
        // ~0.05, a verbatim match ~0.85–0.90), so it's interpretable as-is.
        entry[@"score"] = @(r.score);
        if (r.memory.summary.length > 0) {
            entry[@"summary"] = r.memory.summary;
        }
        [output addObject:entry];
        [rankedIDs addObject:r.memory.objectID];
        [searchScores addObject:@(r.score)];
    }

    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeSearch
                                   objectIDs:rankedIDs
                                      scores:searchScores
                                    originID:nil];

    // Report the effective focus: caller's override if present, otherwise
    // the engine default (no recency weighting).
    NSString *effectiveDecay = focusOverride ?: [ESVectorEngine defaultDecayLevel];

    NSMutableDictionary *response = [@{
        @"query": query,
        @"count": @(output.count),
        @"focus": [ESVectorEngine decayLevelDescriptions][effectiveDecay] ?: effectiveDecay,
        @"results": output
    } mutableCopy];
    if (tagNames) {
        response[@"tags"] = tagNames;
    }
    return response;
}

@end
