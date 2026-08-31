//
//  ESMemoryTaggedTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_tagged
//  "Retrieve by entity tag. For proper nouns."
//
//  Paginated. Dense tags (hundreds of members) would otherwise flood the
//  client's context window — see the pagination dialect note in CLAUDE.md.
//

#import "ESMemoryTaggedTool.h"
#import "CDTag.h"
#import "CDMemory.h"
#import "ESMemoryToolBase.h"

static const NSUInteger kDefaultLimit = 50;
static const NSUInteger kMaxLimit     = 500;

static NSString *const kSortRecent       = @"recent";
static NSString *const kSortOldest       = @"oldest";
static NSString *const kSortAccessed     = @"accessed";
static NSString *const kSortPopular      = @"popular";
static NSString *const kSortAlphabetical = @"alphabetical";

@implementation ESMemoryTaggedTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_tagged",
        @"description": @"Retrieve by entity tag. For proper nouns. Paginated — dense tags (hundreds of members) return a page at a time. Use `total` / `truncated` in the response to know whether more exist.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"tag": @{@"type": @"string", @"description": @"Tag name."},
                @"include_summary": @{@"description": @"If true, include each entry's summary in results — lets you skim a large tag cluster without N archive_read calls. Default false (titles only).", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"limit": @{@"description": @"Maximum number of results to return. Default 50, max 500.", @"oneOf": @[@{@"type": @"integer", @"minimum": @1, @"maximum": @500}, @{@"type": @"string"}]},
                @"offset": @{@"description": @"Skip this many results before applying limit. Default 0. Use for pagination.", @"oneOf": @[@{@"type": @"integer", @"minimum": @0}, @{@"type": @"string"}]},
                @"sort": @{@"type": @"string", @"description": @"Ordering for deterministic pagination. Default: recent (dateModified desc). Other values: oldest (dateCreated asc), accessed (dateAccessed desc, never-accessed last), popular (accessCount desc), alphabetical (title asc).", @"enum": @[@"recent", @"oldest", @"accessed", @"popular", @"alphabetical"]}
            },
            @"required": @[@"tag"]
        }
    };
}

/// Sort the memories into a stable order matching the requested sort mode.
/// NSSortDescriptor alone doesn't cleanly express "nulls last" for optional
/// date keys, so we use a comparator block for date-keyed sorts.
static NSArray<CDMemory *> *SortMemories(NSArray<CDMemory *> *memories,
                                         NSString *sortMode) {
    if ([sortMode isEqualToString:kSortPopular]) {
        return [memories sortedArrayUsingDescriptors:@[
            [NSSortDescriptor sortDescriptorWithKey:@"accessCount" ascending:NO],
            // tie-break for determinism
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ]];
    }
    if ([sortMode isEqualToString:kSortAlphabetical]) {
        return [memories sortedArrayUsingDescriptors:@[
            [NSSortDescriptor sortDescriptorWithKey:@"title"
                                          ascending:YES
                                           selector:@selector(caseInsensitiveCompare:)],
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ]];
    }

    // Date-keyed sorts need nulls-last handling and direction control.
    NSString *key;
    BOOL ascending;
    if ([sortMode isEqualToString:kSortOldest]) {
        key = @"dateCreated"; ascending = YES;
    } else if ([sortMode isEqualToString:kSortAccessed]) {
        key = @"dateAccessed"; ascending = NO;
    } else {
        // Default / kSortRecent
        key = @"dateModified"; ascending = NO;
    }

    return [memories sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        NSDate *da = [a valueForKey:key];
        NSDate *db = [b valueForKey:key];
        // nils always sort last regardless of ascending/descending
        if (!da && !db) return NSOrderedSame;
        if (!da)       return NSOrderedDescending;
        if (!db)       return NSOrderedAscending;
        NSComparisonResult r = [da compare:db];
        return ascending ? r : (r == NSOrderedAscending ? NSOrderedDescending
                              : r == NSOrderedDescending ? NSOrderedAscending
                              : NSOrderedSame);
    }];
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *tagName = arguments[@"tag"];
    if (!tagName || ![tagName isKindOfClass:NSString.class] || tagName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: @"'tag' is required"}];
        }
        return nil;
    }

    // Pagination params.
    NSUInteger limit = [ESMemoryToolBase unsignedIntegerFromArgs:arguments
                                                             key:@"limit"
                                                         default:kDefaultLimit];
    if (limit == 0) limit = kDefaultLimit;
    if (limit > kMaxLimit) limit = kMaxLimit;

    NSUInteger offset = [ESMemoryToolBase unsignedIntegerFromArgs:arguments
                                                              key:@"offset"
                                                          default:0];

    // Sort mode — default "recent", validate explicit values.
    NSString *sortMode = [ESMemoryToolBase stringFromArgs:arguments key:@"sort"] ?: kSortRecent;
    NSSet *validSorts = [NSSet setWithArray:@[kSortRecent, kSortOldest, kSortAccessed,
                                               kSortPopular, kSortAlphabetical]];
    if (![validSorts containsObject:sortMode]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Invalid sort: '%@'. Valid: recent, oldest, accessed, popular, alphabetical.", sortMode]}];
        }
        return nil;
    }

    BOOL includeSummary = [ESMemoryToolBase boolFromArgs:arguments
                                                     key:@"include_summary"
                                                 default:NO];

    NSManagedObjectContext *ctx = store.viewContext;
    CDTag *tag = [CDTag findByName:tagName context:ctx];

    if (!tag) {
        return @{
            @"tag": tagName,
            @"kind": @"unknown",
            @"count": @0,
            @"total": @0,
            @"offset": @(offset),
            @"limit": @(limit),
            @"sort": sortMode,
            @"truncated": @NO,
            @"results": @[]
        };
    }

    // Gather head memories (filter out CDMemoryRevision sub-entities), scoped to
    // the connecting persona — a tag is global but each persona sees only its
    // own tagged memories. `total` therefore counts in-silo members, keeping
    // pagination correct.
    NSMutableArray<CDMemory *> *matches = [NSMutableArray array];
    for (CDMemory *m in tag.memories) {
        if ([m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) continue;
        if (![m.author isEqualToString:scope.author]) continue;
        [matches addObject:m];
    }

    NSUInteger total = matches.count;

    // Sort deterministically so pagination is stable across calls.
    NSArray<CDMemory *> *sorted = SortMemories(matches, sortMode);

    // Slice [offset, offset + limit) — clamped.
    NSUInteger sliceStart = MIN(offset, total);
    NSUInteger sliceEnd   = MIN(sliceStart + limit, total);
    NSArray<CDMemory *> *page = [sorted subarrayWithRange:NSMakeRange(sliceStart, sliceEnd - sliceStart)];

    // Build result rows + id list.
    NSMutableArray *results      = [NSMutableArray arrayWithCapacity:page.count];
    NSMutableArray *matchingIDs  = [NSMutableArray arrayWithCapacity:page.count];
    for (CDMemory *m in page) {
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:(m.title ?: @"Untitled")
                                                                     forKey:@"title"];
        if (includeSummary) {
            row[@"summary"] = m.summary ?: @"";
        }
        [results addObject:row];
        [matchingIDs addObject:m.objectID];
    }

    // Notify Archive Scope only for the actually-returned subset.
    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeTagged
                                   objectIDs:matchingIDs
                                      scores:nil
                                    originID:nil];

    return @{
        @"tag": tag.name ?: tagName,
        @"kind": tag.kind ?: @"thing",
        @"count": @(results.count),
        @"total": @(total),
        @"offset": @(sliceStart),
        @"limit": @(limit),
        @"sort": sortMode,
        @"truncated": @(sliceEnd < total),
        @"results": results
    };
}

@end
