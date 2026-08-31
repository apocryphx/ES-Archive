//
//  ESMemoryTagTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_tag
//  "Add tags without modifying body."
//

#import "ESMemoryTagTool.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryTagTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_tag",
        @"description": @"Attach tags to an entry. Any tag that doesn't exist yet is created automatically (connect-or-create, kind 'thing'); newly-created names come back under 'createdTags'. When kind or expiry matters, provision the tag first via archive_tags mode=create.",
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
                    @"description": @"Names of tags to attach. Pass an array of {name} or {name, kind} objects, an array of name strings, or a comma-separated string. Tags that don't exist yet are created (kind defaults to 'thing').",
                    @"oneOf": @[
                        @{
                            @"type": @"array",
                            @"items": @{
                                @"type": @"object",
                                @"properties": @{
                                    @"name": @{@"type": @"string"},
                                    @"kind": @{@"type": @"string"}
                                },
                                @"required": @[@"name"]
                            }
                        },
                        @{
                            @"type": @"array",
                            @"items": @{@"type": @"string"}
                        },
                        @{
                            @"type": @"string"
                        }
                    ]
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

    // Connect-or-create: attach each named tag, creating any that don't exist.
    NSArray<NSDictionary *> *tagDicts = [ESMemoryToolBase tagArrayFromArgs:arguments key:@"tags"];
    NSMutableArray<NSString *> *createdTags = [NSMutableArray array];
    for (NSDictionary *td in tagDicts) {
        NSString *name = td[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        if (![CDTag findByName:name context:ctx]) [createdTags addObject:name];
        CDTag *tag = [CDTag findOrCreateByName:name kind:td[@"kind"] context:ctx];
        if (tag) [memory addTagsObject:tag];
    }

    [[ESCoreDataStack shared] saveContext];

    NSMutableArray *tags = [NSMutableArray array];
    for (CDTag *t in memory.tags) {
        [tags addObject:@{@"name": t.name ?: @"", @"kind": t.kind ?: @"thing"}];
    }

    NSMutableDictionary *resp = [@{@"status": @"tagged", @"title": memory.title ?: @"", @"tags": tags} mutableCopy];
    if (createdTags.count > 0) resp[@"createdTags"] = createdTags;
    return resp;
}

@end
