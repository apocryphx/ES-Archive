//
//  ESMemoryEraseTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_erase
//  "Permanently erase a memory by title. Irreversible."
//  Cascade deletes revisions, links, tag associations, vector, attachments, marginalia.
//

#import "ESMemoryEraseTool.h"
#import "CDMemory.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"

@implementation ESMemoryEraseTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_erase",
        @"description": @"Permanently erase an entry. Irreversible — read the entry first and consider updating instead.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @YES,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title":  @{@"type": @"string", @"description": @"Title of entry to erase."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index":  @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]}
            },
            @"required": @[@"title"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *title = arguments[@"title"];
    if (!title || ![title isKindOfClass:NSString.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: @"'title' is required"}];
        }
        return nil;
    }

    NSManagedObjectContext *ctx = store.viewContext;
    CDMemoryLookupResult *lookup = [CDMemoryLookup findScopedMemoryWithTitle:title
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
    NSString *erasedTitle = memory.title ?: @"Untitled";
    [ctx deleteObject:memory]; // Cascade handles revisions, links, vector, attachments, marginalia

    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        if (error) *error = saveError;
        return nil;
    }

    return @{@"status": @"erased", @"title": erasedTitle};
}

@end
