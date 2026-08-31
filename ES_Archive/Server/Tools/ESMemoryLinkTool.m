//
//  ESMemoryLinkTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_link
//  "Create directional relationship. Use sparingly."
//

#import "ESMemoryLinkTool.h"
#import "CDMemory.h"
#import "CDLink.h"
#import "CDLink+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"

@implementation ESMemoryLinkTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_link",
        @"description": @"Directional edge between entries. Use sparingly — let the graph emerge from real relationships.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"sourceTitle": @{@"type": @"string", @"description": @"Source entry title."},
                @"sourceIndex": @{@"description": @"Disambiguation index for sourceTitle when several entries share it (from an ambiguous_source response).", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"targetTitle": @{@"type": @"string", @"description": @"Target entry title."},
                @"targetIndex": @{@"description": @"Disambiguation index for targetTitle when several entries share it (from an ambiguous_target response).", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"linkTitle": @{@"type": @"string", @"description": @"Optional name for the link. archive_unlink can target a specific link by this name."},
                @"edge": @{@"type": @"string", @"description": @"The load-bearing semantic axis: a short verb naming how source relates to target (e.g. contradicts, disputes, corrects, revises, elaborates, answers). This is the ONE field archive_links can filter on (edge_filter) — set it whenever the relationship should be traversable by kind."},
                @"type": @{@"type": @"string", @"description": @"Optional coarse structural class (e.g. reference, sequel, derivation). Free-form and NOT filterable — prefer edge when unsure which to set."},
                @"tone": @{@"type": @"string", @"description": @"Optional emotional quality of the relationship. Free-form annotation; not filterable."}
            },
            @"required": @[@"sourceTitle", @"targetTitle"]
        }
    };
}

// Ambiguity response for one endpoint of the link. Mirrors the matches shape
// the single-memory tools return, but names the endpoint (source/target) and
// the index parameter that resolves it.
static NSDictionary *AmbiguousEndpointResponse(NSString *status,
                                               NSArray<CDMemory *> *matches,
                                               NSString *indexParam) {
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:matches.count];
    NSInteger i = 0;
    for (CDMemory *m in matches) {
        [entries addObject:@{
            @"index": @(i++),
            @"title": m.title ?: @"",
            @"dateCreated": m.dateCreated ? [df stringFromDate:m.dateCreated] : @"",
            @"author": m.author ?: @""
        }];
    }
    return @{
        @"status": status,
        @"matches": entries,
        @"hint": [NSString stringWithFormat:@"Several entries share this title. Retry with %@ set to the intended match.", indexParam]
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSManagedObjectContext *ctx = store.viewContext;

    // Both ends resolve through the persona scope — you can only link memories
    // you own, so cross-persona links are blocked by construction.
    CDMemoryLookupResult *sourceLookup = [CDMemoryLookup findScopedMemoryWithTitle:arguments[@"sourceTitle"]
                                                                      scopeAuthor:scope.author
                                                                    disambiguator:nil
                                                                            index:arguments[@"sourceIndex"]
                                                                          context:ctx];
    if (sourceLookup.status == CDMemoryLookupAmbiguous) {
        return AmbiguousEndpointResponse(@"ambiguous_source", sourceLookup.matches, @"sourceIndex");
    }
    if (sourceLookup.status != CDMemoryLookupFound) {
        return @{@"status": @"source_not_found", @"title": arguments[@"sourceTitle"] ?: @""};
    }

    CDMemoryLookupResult *targetLookup = [CDMemoryLookup findScopedMemoryWithTitle:arguments[@"targetTitle"]
                                                                      scopeAuthor:scope.author
                                                                    disambiguator:nil
                                                                            index:arguments[@"targetIndex"]
                                                                          context:ctx];
    if (targetLookup.status == CDMemoryLookupAmbiguous) {
        return AmbiguousEndpointResponse(@"ambiguous_target", targetLookup.matches, @"targetIndex");
    }
    if (targetLookup.status != CDMemoryLookupFound) {
        return @{@"status": @"target_not_found", @"title": arguments[@"targetTitle"] ?: @""};
    }

    CDLink *link = [NSEntityDescription insertNewObjectForEntityForName:@"CDLink"
                                                inManagedObjectContext:ctx];
    link.uuid = [NSUUID UUID];
    link.dateCreated = [NSDate now];
    link.sourceMemory = sourceLookup.memory;
    link.targetMemory = targetLookup.memory;
    link.linkTitle = arguments[@"linkTitle"];
    link.linkType = arguments[@"type"];
    link.tone = arguments[@"tone"];
    link.edge = arguments[@"edge"];

    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        if (error) *error = saveError;
        return nil;
    }

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    return @{
        @"status": @"linked",
        @"sourceTitle": sourceLookup.memory.title ?: @"",
        @"targetTitle": targetLookup.memory.title ?: @"",
        @"dateCreated": [df stringFromDate:link.dateCreated]
    };
}

@end
