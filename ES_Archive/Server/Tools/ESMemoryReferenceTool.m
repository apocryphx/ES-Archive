//
//  ESMemoryReferenceTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_reference
//  Typed, durable pointers to external resources on a memory. op = add / list / remove.
//  A reference holds NO payload — the document lives elsewhere (disk, Drive, a DOI/URL)
//  and is resolved on demand by an agent. This is the successor to archive_attachment.
//

#import "ESMemoryReferenceTool.h"
#import "CDMemory.h"
#import "CDReference.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryReferenceTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_reference",
        @"description": @"Typed, durable pointers to external resources on an entry — a document, paper, "
                         "Drive file, or local file. A reference holds NO content; the source lives elsewhere "
                         "and is resolved on demand (hand the handle to the Drive/web tools). "
                         "op=add records a reference; op=list returns an entry's references; "
                         "op=remove deletes one by its exact dateCreated.",
        @"annotations": @{ @"readOnlyHint": @NO, @"destructiveHint": @NO, @"idempotentHint": @NO },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"op": @{@"type": @"string", @"description": @"add, list, remove.", @"enum": @[@"add", @"list", @"remove"]},
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"type": @{@"type": @"string", @"description": @"Resolver scheme (add): drive | doi | url | path | bookmark | arxiv | …"},
                @"handle": @{@"type": @"string", @"description": @"Durable token to resolve (add): Drive fileId, DOI, URL, absolute path."},
                @"referenceTitle": @{@"type": @"string", @"description": @"Human/gist label for the reference (add). (Legacy spelling reference_title is still accepted.)"},
                @"url": @{@"type": @"string", @"description": @"Optional human-clickable canonical URL (add)."},
                @"contentType": @{@"type": @"string", @"description": @"Optional MIME of the target document, e.g. application/pdf (add)."},
                @"note": @{@"type": @"string", @"description": @"Optional one-line annotation — why it's here / the relevant bit (add)."},
                @"bookmark": @{@"type": @"string", @"description": @"Optional base64 security-scoped bookmark for a local file (add, type=bookmark)."},
                @"date": @{@"type": @"string", @"description": @"Exact dateCreated (ISO8601) of the reference to remove (remove)."}
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
    } else if ([op isEqualToString:@"list"]) {
        return [self listFromMemory:memory];
    }
    return @{@"status": @"unknown_op", @"hint": @"add, list, remove"};
}

+ (NSDictionary *)addToMemory:(CDMemory *)memory
                     arguments:(NSDictionary *)arguments
                   scopeAuthor:(NSString *)scopeAuthor
                       context:(NSManagedObjectContext *)ctx {

    NSString *type = [ESMemoryToolBase stringFromArgs:arguments key:@"type"];
    if (!type) return @{@"status": @"missing_type",
                        @"hint": @"type is the resolver scheme: drive, doi, url, path, bookmark, …"};

    NSString *handle      = [ESMemoryToolBase stringFromArgs:arguments key:@"handle"];
    NSString *bookmarkB64 = [ESMemoryToolBase stringFromArgs:arguments key:@"bookmark"];
    if (!handle && !bookmarkB64) {
        return @{@"status": @"missing_handle",
                 @"hint": @"provide handle (the durable token) — or a base64 bookmark for a local file."};
    }

    NSData *bookmarkData = nil;
    if (bookmarkB64) {
        bookmarkData = [[NSData alloc] initWithBase64EncodedString:bookmarkB64 options:0];
        if (!bookmarkData) return @{@"status": @"error", @"message": @"Invalid base64 bookmark."};
    }

    NSString *author = [ESMemoryToolBase effectiveAuthorForScope:scopeAuthor
                                                        explicit:arguments[@"author"]];

    CDReference *ref = [CDReference createOnMemory:memory
                                             type:type
                                           handle:handle
                                            title:([ESMemoryToolBase stringFromArgs:arguments key:@"referenceTitle"]
                                                   ?: [ESMemoryToolBase stringFromArgs:arguments key:@"reference_title"])
                                              url:[ESMemoryToolBase stringFromArgs:arguments key:@"url"]
                                      contentType:[ESMemoryToolBase stringFromArgs:arguments key:@"contentType"]
                                             note:[ESMemoryToolBase stringFromArgs:arguments key:@"note"]
                                           author:author
                                          context:ctx];
    if (bookmarkData) ref.bookmark = bookmarkData;

    [[ESCoreDataStack shared] saveContext];

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    return @{
        @"status": @"added",
        @"entry_title": memory.title ?: @"Untitled",
        @"type": ref.type ?: @"",
        @"handle": ref.handle ?: @"",
        @"referenceTitle": ref.title ?: @"",
        @"dateCreated": ref.dateCreated ? [df stringFromDate:ref.dateCreated] : @""
    };
}

+ (NSDictionary *)removeFromMemory:(CDMemory *)memory
                          arguments:(NSDictionary *)arguments
                            context:(NSManagedObjectContext *)ctx {

    NSString *dateStr = [ESMemoryToolBase stringFromArgs:arguments key:@"date"];
    if (!dateStr) return @{@"status": @"missing_date"};

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSDate *targetDate = [df dateFromString:dateStr];
    if (!targetDate) return @{@"status": @"error", @"message": @"Invalid ISO8601 date."};

    CDReference *target = nil;
    for (CDReference *ref in memory.references) {
        if (fabs([ref.dateCreated timeIntervalSinceDate:targetDate]) < 1.0) {
            target = ref;
            break;
        }
    }
    if (!target) return @{@"status": @"not_found", @"message": @"No reference with that timestamp."};

    NSString *label = target.title ?: target.handle ?: @"reference";
    [ctx deleteObject:target];
    [[ESCoreDataStack shared] saveContext];

    return @{
        @"status": @"removed",
        @"entry_title": memory.title ?: @"Untitled",
        @"referenceTitle": label
    };
}

+ (NSDictionary *)listFromMemory:(CDMemory *)memory {
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES];
    NSArray<CDReference *> *sorted = [memory.references sortedArrayUsingDescriptors:@[sort]];

    NSMutableArray *list = [NSMutableArray array];
    for (CDReference *ref in sorted) {
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        e[@"type"] = ref.type ?: @"";
        if (ref.handle.length)      e[@"handle"]      = ref.handle;
        if (ref.title.length)       e[@"title"]       = ref.title;
        if (ref.url.length)         e[@"url"]         = ref.url;
        if (ref.contentType.length) e[@"contentType"] = ref.contentType;
        if (ref.note.length)        e[@"note"]        = ref.note;
        if (ref.bookmark)           e[@"bookmark"]    = @YES;
        e[@"author"] = ref.author ?: @"";
        e[@"date"]   = ref.dateCreated ? [df stringFromDate:ref.dateCreated] : @"";
        [list addObject:e];
    }
    return @{
        @"status": @"ok",
        @"entry_title": memory.title ?: @"Untitled",
        @"references": list
    };
}

@end
