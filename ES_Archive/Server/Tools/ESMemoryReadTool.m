//
//  ESMemoryReadTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_read
//  "Full content. Includes similar memories with scores and connections."
//  Increments accessCount and updates dateAccessed.
//

#import "ESMemoryReadTool.h"
#import "CDMemory.h"
#import "CDMemoryRevision.h"
#import "CDVector.h"
#import "CDReference.h"
#import "CDMarginalia.h"
#import "CDMemoryLookup.h"
#import "CDTag+CoreDataProperties.h"
#import "ESVectorEngine.h"
#import "ESVectorSearchResult.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryReadTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_read",
        @"description": @"Full content. Includes similar entries with scores and connections. When a topic feels familiar — search. You've almost certainly been here before. Previous sessions left breadcrumbs. Follow them.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]}
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

    // Found
    CDMemory *memory = lookup.memory;
    [memory recordAccess];
    [[ESCoreDataStack shared] saveContext];
    [[ESVectorEngine shared] pushAccessStatsForMemory:memory];

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"title"] = memory.title ?: @"Untitled";
    result[@"author"] = memory.author ?: [CDMemory defaultAuthor];
    result[@"type"] = memory.type ?: @"memory";
    result[@"locked"] = @(memory.locked);
    result[@"private"] = @(memory.private);
    result[@"dateCreated"] = memory.dateCreated ? [df stringFromDate:memory.dateCreated] : @"";
    result[@"dateModified"] = memory.dateModified ? [df stringFromDate:memory.dateModified] : @"";
    result[@"accessCount"] = @(memory.accessCount);
    result[@"revisions"] = @(memory.revisions.count);
    result[@"body"] = memory.body ?: @"";
    if (memory.summary.length > 0) {
        result[@"summary"] = memory.summary;
    }

    // Tags
    NSMutableArray *tags = [NSMutableArray array];
    for (CDTag *tag in memory.tags) {
        [tags addObject:@{
            @"name": tag.name ?: @"",
            @"kind": tag.kind ?: @"thing"
        }];
    }
    result[@"tags"] = tags;

    // References — typed pointers to external sources (no content held here)
    NSSortDescriptor *refSort = [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES];
    NSArray<CDReference *> *sortedRefs = [memory.references sortedArrayUsingDescriptors:@[refSort]];
    NSMutableArray *references = [NSMutableArray array];
    for (CDReference *ref in sortedRefs) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"type"] = ref.type ?: @"";
        if (ref.handle.length)      entry[@"handle"]      = ref.handle;
        if (ref.title.length)       entry[@"title"]       = ref.title;
        if (ref.url.length)         entry[@"url"]         = ref.url;
        if (ref.contentType.length) entry[@"contentType"] = ref.contentType;
        if (ref.note.length)        entry[@"note"]        = ref.note;
        if (ref.bookmark)           entry[@"bookmark"]    = @YES;
        entry[@"author"] = ref.author ?: @"";
        entry[@"date"]   = ref.dateCreated ? [df stringFromDate:ref.dateCreated] : @"";
        [references addObject:entry];
    }
    result[@"references"] = references;

    // Comments (marginalia)
    NSSortDescriptor *noteSort = [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES];
    NSArray<CDMarginalia *> *sortedNotes = [memory.marginalia sortedArrayUsingDescriptors:@[noteSort]];
    NSMutableArray *comments = [NSMutableArray array];
    for (CDMarginalia *note in sortedNotes) {
        [comments addObject:@{
            @"body": note.body ?: @"",
            @"author": note.author ?: @"",
            @"date": note.dateCreated ? [df stringFromDate:note.dateCreated] : @""
        }];
    }
    result[@"comments"] = comments;

    // Similar memories (vector search), scoped to this persona's own vectors so
    // the flare never surfaces another persona's titles.
    NSMutableSet<NSManagedObjectID *> *scopedVectorIDs = [NSMutableSet set];
    {
        NSFetchRequest *vfetch = [CDMemory fetchRequest];
        vfetch.predicate = [ESMemoryToolBase scopePredicateForAuthor:scope.author];
        vfetch.includesSubentities = NO;
        vfetch.relationshipKeyPathsForPrefetching = @[@"vector"];
        NSArray<CDMemory *> *scoped = [ctx executeFetchRequest:vfetch error:nil];
        for (CDMemory *sm in scoped) {
            CDVector *sv = [sm vectorForActiveEmbedder];
            if (sv) [scopedVectorIDs addObject:sv.objectID];
        }
    }
    NSArray<ESVectorSearchResult *> *similar = [[ESVectorEngine shared] similarToMemory:memory
                                                                                  limit:5
                                                                       allowedVectorIDs:scopedVectorIDs];
    NSMutableArray *similarOut = [NSMutableArray array];
    for (ESVectorSearchResult *r in similar) {
        if ([r.memory.uuid isEqual:memory.uuid]) continue; // Skip self
        // Rescaled score only — raw cosine is too compressed to be useful
        // at the LLM surface. Internal callers can read rawScore directly.
        [similarOut addObject:@{
            @"title": r.memory.title ?: @"",
            @"score": @(r.score)
        }];
    }
    result[@"similar"] = similarOut;

    // Connections (graph)
    result[@"connections"] = [memory connectedMemorySummaries];

    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeRead
                                   objectIDs:@[memory.objectID]
                                      scores:nil
                                    originID:nil];

    return result;
}

@end
