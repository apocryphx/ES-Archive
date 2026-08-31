//
//  ESMemoryUntagTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_untag
//  "Remove tags without modifying body."
//

#import "ESMemoryUntagTool.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryUntagTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_untag",
        @"description": @"Remove tags without modifying body.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO,
            @"idempotentHint": @YES
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"tags": @{
                    @"type": @"array",
                    @"description": @"Tag names to remove.",
                    @"items": @{@"type": @"string"}
                }
            },
            @"required": @[@"title", @"tags"]
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

    if (lookup.status == CDMemoryLookupNotFound) return @{@"status": @"not_found"};
    if (lookup.status == CDMemoryLookupAmbiguous) {
        NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
        NSMutableArray *matches = [NSMutableArray array];
        NSInteger i = 0;
        for (CDMemory *m in lookup.matches) {
            [matches addObject:@{@"index": @(i++), @"title": m.title ?: @"", @"dateCreated": m.dateCreated ? [df stringFromDate:m.dateCreated] : @"", @"author": m.author ?: @""}];
        }
        return @{@"status": @"ambiguous", @"matches": matches};
    }

    CDMemory *memory = lookup.memory;
    NSArray *tagNames = [ESMemoryToolBase arrayFromArgs:arguments key:@"tags"];

    for (NSString *name in tagNames) {
        if (![name isKindOfClass:NSString.class]) continue;
        CDTag *tag = [CDTag findByName:name context:ctx];
        if (tag) {
            [memory removeTagsObject:tag];
        }
    }

    [[ESCoreDataStack shared] saveContext];

    NSMutableArray *remaining = [NSMutableArray array];
    for (CDTag *t in memory.tags) {
        [remaining addObject:@{@"name": t.name ?: @"", @"kind": t.kind ?: @"thing"}];
    }

    return @{@"status": @"untagged", @"title": memory.title ?: @"", @"tags": remaining};
}

@end
