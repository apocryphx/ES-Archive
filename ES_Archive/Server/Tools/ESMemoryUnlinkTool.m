//
//  ESMemoryUnlinkTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_unlink
//  "Remove edges between memories — the counterpart to archive_link."
//

#import "ESMemoryUnlinkTool.h"
#import "ESMemoryToolBase.h"
#import "CDMemory.h"
#import "CDLink.h"
#import "CDLink+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import "ESCoreDataStack.h"

@implementation ESMemoryUnlinkTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_unlink",
        @"description": @"Remove edges between entries — the counterpart to archive_link. "
                         "Give sourceTitle + targetTitle to remove the link(s) between two entries "
                         "(either direction; optionally only the one named by linkTitle), or "
                         "sourceTitle + all=true to strip EVERY link touching one entry — e.g. "
                         "de-starring an over-connected index node. Returns the number removed.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @YES,
            @"idempotentHint": @YES
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"sourceTitle": @{@"type": @"string", @"description": @"The entry whose link(s) to remove."},
                @"sourceIndex": @{@"description": @"Disambiguation index for sourceTitle when several entries share it (from an ambiguous_source response).", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"targetTitle": @{@"type": @"string", @"description": @"Optional. Remove only the link(s) between source and this target, in either direction."},
                @"targetIndex": @{@"description": @"Disambiguation index for targetTitle when several entries share it (from an ambiguous_target response).", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"linkTitle": @{@"type": @"string", @"description": @"Optional. With targetTitle, remove only the link with this name."},
                @"all": @{@"description": @"Optional. If true (and no targetTitle), remove EVERY link touching sourceTitle. Use to de-star an over-connected hub.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]}
            },
            @"required": @[@"sourceTitle"]
        }
    };
}

// Ambiguity response for one endpoint — same shape as archive_link's.
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

    // Source resolves through the persona scope — you can only unlink within
    // your own archive, mirroring archive_link.
    CDMemoryLookupResult *srcLookup = [CDMemoryLookup findScopedMemoryWithTitle:arguments[@"sourceTitle"]
                                                                    scopeAuthor:scope.author
                                                                  disambiguator:nil
                                                                          index:arguments[@"sourceIndex"]
                                                                        context:ctx];
    if (srcLookup.status == CDMemoryLookupAmbiguous) {
        return AmbiguousEndpointResponse(@"ambiguous_source", srcLookup.matches, @"sourceIndex");
    }
    if (srcLookup.status != CDMemoryLookupFound) {
        return @{@"status": @"source_not_found", @"title": arguments[@"sourceTitle"] ?: @""};
    }
    CDMemory *src = srcLookup.memory;

    BOOL all = [ESMemoryToolBase boolFromArgs:arguments key:@"all" default:NO];
    NSString *targetTitle = [ESMemoryToolBase stringFromArgs:arguments key:@"targetTitle"];
    NSString *linkTitle = [ESMemoryToolBase stringFromArgs:arguments key:@"linkTitle"];

    NSMutableArray<CDLink *> *toRemove = [NSMutableArray array];

    if (targetTitle) {
        CDMemoryLookupResult *tgtLookup = [CDMemoryLookup findScopedMemoryWithTitle:targetTitle
                                                                        scopeAuthor:scope.author
                                                                      disambiguator:nil
                                                                              index:arguments[@"targetIndex"]
                                                                            context:ctx];
        if (tgtLookup.status == CDMemoryLookupAmbiguous) {
            return AmbiguousEndpointResponse(@"ambiguous_target", tgtLookup.matches, @"targetIndex");
        }
        if (tgtLookup.status != CDMemoryLookupFound) {
            return @{@"status": @"target_not_found", @"title": targetTitle};
        }
        CDMemory *tgt = tgtLookup.memory;
        // Links between source and target, in either direction.
        for (CDLink *l in src.sourceLinks) if (l.targetMemory == tgt) [toRemove addObject:l];
        for (CDLink *l in src.targetLinks) if (l.sourceMemory == tgt) [toRemove addObject:l];
        if (linkTitle.length > 0) {
            NSMutableArray<CDLink *> *named = [NSMutableArray array];
            for (CDLink *l in toRemove) if ([l.linkTitle isEqualToString:linkTitle]) [named addObject:l];
            toRemove = named;
        }
    } else if (all) {
        // Strip every edge touching source — the de-star operation.
        [toRemove addObjectsFromArray:src.sourceLinks.allObjects];
        [toRemove addObjectsFromArray:src.targetLinks.allObjects];
    } else {
        return @{@"status": @"need_target_or_all",
                 @"hint": @"Provide targetTitle, or all=true to strip every link touching sourceTitle."};
    }

    NSUInteger removed = toRemove.count;
    for (CDLink *l in toRemove) [ctx deleteObject:l];

    if (removed > 0) {
        NSError *saveError = nil;
        if (![ctx save:&saveError]) {
            if (error) *error = saveError;
            return nil;
        }
    }

    return @{
        @"status": @"unlinked",
        @"sourceTitle": src.title ?: @"",
        @"removed": @(removed)
    };
}

@end
