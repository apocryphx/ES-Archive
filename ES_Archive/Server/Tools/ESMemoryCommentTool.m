//
//  ESMemoryCommentTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_comment
//  Unified marginal-note CRUD. `op` selects add / remove.
//  Reading is via archive_read (comments are returned inline).
//

#import "ESMemoryCommentTool.h"
#import "CDMemory.h"
#import "CDMarginalia.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryCommentTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_comment",
        @"description": @"Marginal-note CRUD on an entry. op=add writes a marginal note (does not modify the entry itself — the conversation grows around it). op=remove deletes by exact dateCreated. Read comments via archive_read.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"op": @{@"type": @"string", @"description": @"add, remove.", @"enum": @[@"add", @"remove"]},
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"note": @{@"type": @"string", @"description": @"The marginal note. Plain text. Brevity is the point (add)."},
                @"annotator": @{@"type": @"string", @"description": @"Who is writing this note. Defaults to AI (add)."},
                @"date": @{@"type": @"string", @"description": @"Exact dateCreated (ISO8601) of the comment to remove (remove)."}
            },
            @"required": @[@"op", @"title"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *op = [ESMemoryToolBase stringFromArgs:arguments key:@"op"];
    if (!op) return @{@"status": @"missing_op"};

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

    if ([op isEqualToString:@"add"]) {
        return [self addToMemory:memory arguments:arguments scopeAuthor:scope.author context:ctx];
    } else if ([op isEqualToString:@"remove"]) {
        return [self removeFromMemory:memory arguments:arguments context:ctx];
    }

    return @{@"status": @"unknown_op", @"hint": @"add, remove"};
}

+ (NSDictionary *)addToMemory:(CDMemory *)memory
                     arguments:(NSDictionary *)arguments
                   scopeAuthor:(NSString *)scopeAuthor
                       context:(NSManagedObjectContext *)ctx {
    NSString *body = [ESMemoryToolBase stringFromArgs:arguments key:@"note"];
    if (!body) return @{@"status": @"missing_note"};

    NSString *annotator = [ESMemoryToolBase effectiveAuthorForScope:scopeAuthor
                                                           explicit:arguments[@"annotator"]];

    CDMarginalia *note = [CDMarginalia createOnMemory:memory
                                                 body:body
                                               author:annotator
                                              context:ctx];

    [[ESCoreDataStack shared] saveContext];

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    return @{
        @"status": @"noted",
        @"entry_title": memory.title ?: @"Untitled",
        @"dateCreated": note.dateCreated ? [df stringFromDate:note.dateCreated] : @""
    };
}

+ (NSDictionary *)removeFromMemory:(CDMemory *)memory
                          arguments:(NSDictionary *)arguments
                            context:(NSManagedObjectContext *)ctx {
    NSString *dateStr = [ESMemoryToolBase stringFromArgs:arguments key:@"date"];
    if (!dateStr) return @{@"status": @"missing_date"};

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSDate *targetDate = [df dateFromString:dateStr];
    if (!targetDate) {
        return @{@"status": @"error", @"message": @"Invalid ISO8601 date."};
    }

    CDMarginalia *target = nil;
    for (CDMarginalia *note in memory.marginalia) {
        if (fabs([note.dateCreated timeIntervalSinceDate:targetDate]) < 1.0) {
            target = note;
            break;
        }
    }

    if (!target) {
        return @{@"status": @"not_found", @"message": @"No comment with that timestamp."};
    }

    [ctx deleteObject:target];
    [[ESCoreDataStack shared] saveContext];

    return @{
        @"status": @"removed",
        @"entry_title": memory.title ?: @"Untitled"
    };
}

@end
