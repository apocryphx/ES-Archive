//
//  ESMemoryLinksTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_links
//  "Graph exploration without reading body."
//

#import "ESMemoryLinksTool.h"
#import "CDMemory.h"
#import "CDMemoryLookup.h"
#import "CDLink.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryLinksTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_links",
        @"description": @"Graph exploration without reading body. Follow edges outward from something you've found.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"edge_filter": @{
                    @"type": @"array",
                    @"items": @{@"type": @"string"},
                    @"description": @"Only return links whose edge value matches one of these (case-insensitive). Use the disagreement-edge taxonomy from CLAUDE.md (`contradicts`, `disputes`, `corrects`, `revises`) to surface only questioning relationships, or pass any free-form edge values your Archive uses. Omit or empty to return all links."
                }
            },
            @"required": @[@"title"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSManagedObjectContext *ctx = store.viewContext;
    CDMemoryLookupResult *lookup = [CDMemoryLookup findScopedMemoryWithTitle:arguments[@"title"]
                                                                scopeAuthor:scope.author
                                                              disambiguator:arguments[@"author"]
                                                                      index:arguments[@"index"]
                                                                    context:ctx];

    if (lookup.status == CDMemoryLookupNotFound) {
        return @{@"status": @"not_found"};
    }

    if (lookup.status == CDMemoryLookupAmbiguous) {
        NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
        NSMutableArray *matches = [NSMutableArray array];
        NSInteger i = 0;
        for (CDMemory *m in lookup.matches) {
            [matches addObject:@{
                @"index": @(i++),
                @"title": m.title ?: @"",
                @"dateCreated": m.dateCreated ? [df stringFromDate:m.dateCreated] : @"",
                @"author": m.author ?: @""
            }];
        }
        return @{@"status": @"ambiguous", @"matches": matches};
    }

    CDMemory *memory = lookup.memory;
    NSArray *links = [memory connectedMemorySummaries];

    // Optional edge filter — case-insensitive match against the link summary's "edge" key.
    NSArray *rawFilter = [ESMemoryToolBase arrayFromArgs:arguments key:@"edge_filter"];
    NSMutableSet<NSString *> *edgeSet = nil;
    if (rawFilter.count > 0) {
        edgeSet = [NSMutableSet set];
        for (id e in rawFilter) {
            if ([e isKindOfClass:NSString.class] && [(NSString *)e length] > 0) {
                [edgeSet addObject:[(NSString *)e lowercaseString]];
            }
        }
        if (edgeSet.count > 0) {
            NSMutableArray *filtered = [NSMutableArray array];
            for (NSDictionary *summary in links) {
                NSString *edge = summary[@"edge"];
                if ([edge isKindOfClass:NSString.class] &&
                    [edgeSet containsObject:edge.lowercaseString]) {
                    [filtered addObject:summary];
                }
            }
            links = filtered;
        } else {
            edgeSet = nil; // empty after coercion → treat as no filter
        }
    }

    // Build neighborIDs aligned with the (possibly filtered) link set so the
    // Archive Scope notification only highlights what we actually returned.
    NSMutableArray *neighborIDs = [NSMutableArray array];
    for (CDLink *link in memory.sourceLinks) {
        if (edgeSet && !(link.edge && [edgeSet containsObject:link.edge.lowercaseString])) continue;
        if (link.targetMemory) [neighborIDs addObject:link.targetMemory.objectID];
    }
    for (CDLink *link in memory.targetLinks) {
        if (edgeSet && !(link.edge && [edgeSet containsObject:link.edge.lowercaseString])) continue;
        if (link.sourceMemory) [neighborIDs addObject:link.sourceMemory.objectID];
    }
    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeLinks
                                   objectIDs:neighborIDs
                                      scores:nil
                                    originID:memory.objectID];

    return @{
        @"title": memory.title ?: @"",
        @"count": @(links.count),
        @"links": links
    };
}

@end
