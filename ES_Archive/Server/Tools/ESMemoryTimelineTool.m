//
//  ESMemoryTimelineTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_timeline
//  "Retrieve by time — oldest or newest, on a chosen axis, within a window."
//
//  Generalizes the former memory_recent (newest-by-modified only) into a
//  bidirectional, axis-selectable, windowable temporal verb. memory_recent
//  is exactly archive_timeline{order:newest, by:modified}.
//

#import "ESMemoryTimelineTool.h"
#import "CDMemory.h"
#import "CDMemoryLookup.h"
#import "CDTag.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryTimelineTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_timeline",
        @"description": @"Retrieve entries by TIME — distinct from archive_search (by meaning) and "
                         "archive_discover (by structural lens). Order oldest or newest along a chosen "
                         "time axis, optionally within a date window. 'most recent' → order:newest; "
                         "'oldest' / 'what did I store first' → order:oldest. "
                         "by: created (default — when it entered the Archive), modified (last edited — "
                         "the former memory_recent was order:newest+by:modified), or accessed (last read). "
                         "from/to bound a window (ISO-8601; the bridge normalizes relative offsets like "
                         "'-30 days'); days is sugar for the last N days. Optional tags scope the "
                         "timeline to a project or entity.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"order": @{@"type": @"string", @"description": @"newest (default) or oldest.", @"enum": @[@"newest", @"oldest"]},
                @"by": @{@"type": @"string", @"description": @"Time axis: created (default), modified, or accessed.", @"enum": @[@"created", @"modified", @"accessed"]},
                @"from": @{@"type": @"string", @"description": @"Window start. ISO-8601 (e.g. 2025-11-01T00:00:00Z); relative offsets like '-30 days' are normalized by the bridge."},
                @"to": @{@"type": @"string", @"description": @"Window end. Same formats as from."},
                @"days": @{@"description": @"Sugar: limit to the last N days on the chosen axis (ignored if from is given).", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"limit": @{@"description": @"Maximum number of results. Default: 20.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"tags": @{
                    @"type": @"array",
                    @"description": @"Restrict to entries carrying ANY of these tags (OR semantics, case-insensitive). Scope the timeline to a project or entity — e.g. tags:[\"Isolde\"].",
                    @"items": @{@"type": @"string"}
                },
                @"include_summary": @{@"description": @"If true, include each entry's summary — skim a timeline without N archive_read calls. Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]}
            }
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSManagedObjectContext *ctx = store.viewContext;

    NSUInteger limit = [ESMemoryToolBase unsignedIntegerFromArgs:arguments key:@"limit" default:20];
    if (limit == 0) limit = 20;

    BOOL includeSummary = [ESMemoryToolBase boolFromArgs:arguments key:@"include_summary" default:NO];

    // Direction: oldest → ascending, anything else → newest (descending).
    NSString *orderArg = [ESMemoryToolBase stringFromArgs:arguments key:@"order"] ?: @"newest";
    BOOL ascending = ([orderArg caseInsensitiveCompare:@"oldest"] == NSOrderedSame);

    // Axis: which date field to sort and window on. Unknown errors rather than
    // silently defaulting — mirrors the pipeline 'sort' discipline.
    NSString *byArg = [ESMemoryToolBase stringFromArgs:arguments key:@"by"] ?: @"created";
    NSString *dateKey = nil;
    if ([byArg caseInsensitiveCompare:@"created"] == NSOrderedSame) dateKey = @"dateCreated";
    else if ([byArg caseInsensitiveCompare:@"modified"] == NSOrderedSame) dateKey = @"dateModified";
    else if ([byArg caseInsensitiveCompare:@"accessed"] == NSOrderedSame) dateKey = @"dateAccessed";
    else return @{@"status": @"invalid_by", @"hint": @"by must be created, modified, or accessed."};

    // Window bounds. from/to arrive as ISO-8601 (the bridge has already
    // normalized any relative offset). days is server-side sugar for from.
    NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
    NSDate *fromDate = nil, *toDate = nil;
    NSString *fromStr = [ESMemoryToolBase stringFromArgs:arguments key:@"from"];
    NSString *toStr = [ESMemoryToolBase stringFromArgs:arguments key:@"to"];
    if (fromStr.length > 0) {
        fromDate = [iso dateFromString:fromStr];
        if (!fromDate) return @{@"status": @"invalid_from",
                                @"hint": @"from must be ISO-8601 (e.g. 2025-11-01T00:00:00Z). Relative offsets are normalized by the bridge."};
    }
    if (toStr.length > 0) {
        toDate = [iso dateFromString:toStr];
        if (!toDate) return @{@"status": @"invalid_to",
                              @"hint": @"to must be ISO-8601 (e.g. 2025-11-30T23:59:59Z). Relative offsets are normalized by the bridge."};
    }
    if (!fromDate && arguments[@"days"]) {
        NSInteger days = [ESMemoryToolBase integerFromArgs:arguments key:@"days" default:0];
        if (days > 0) {
            fromDate = [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay
                                                                value:-days
                                                               toDate:[NSDate now]
                                                              options:0];
        }
    }

    // Optional tags filter (OR semantics, case-insensitive via findByName:).
    NSArray *rawTags = [ESMemoryToolBase arrayFromArgs:arguments key:@"tags"];
    NSMutableArray<NSString *> *tagNames = nil;
    NSMutableArray<CDTag *> *resolvedTags = nil;
    if (rawTags) {
        tagNames = [NSMutableArray array];
        for (id name in rawTags) {
            if ([name isKindOfClass:NSString.class] && [(NSString *)name length] > 0) {
                [tagNames addObject:(NSString *)name];
            }
        }
        if (tagNames.count == 0) {
            tagNames = nil;
        } else {
            resolvedTags = [NSMutableArray array];
            for (NSString *name in tagNames) {
                CDTag *tag = [CDTag findByName:name context:ctx];
                if (tag) [resolvedTags addObject:tag];
            }
            if (resolvedTags.count == 0) {
                return @{
                    @"count": @0,
                    @"results": @[],
                    @"tags": tagNames,
                    @"note": @"No entries carry any of the requested tags."
                };
            }
        }
    }

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO; // Exclude CDMemoryRevision
    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:dateKey ascending:ascending]];
    fetch.fetchLimit = limit;

    // Compound predicate: persona scope (always) AND window bounds AND tags.
    NSMutableArray<NSPredicate *> *clauses = [NSMutableArray array];
    [clauses addObject:[ESMemoryToolBase scopePredicateForAuthor:scope.author]];
    if (fromDate) [clauses addObject:[NSPredicate predicateWithFormat:@"%K >= %@", dateKey, fromDate]];
    if (toDate)   [clauses addObject:[NSPredicate predicateWithFormat:@"%K <= %@", dateKey, toDate]];
    if (resolvedTags) [clauses addObject:[NSPredicate predicateWithFormat:@"ANY tags IN %@", resolvedTags]];
    if (clauses.count == 1) {
        fetch.predicate = clauses.firstObject;
    } else if (clauses.count > 1) {
        fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:clauses];
    }

    NSError *fetchError = nil;
    NSArray<CDMemory *> *memories = [ctx executeFetchRequest:fetch error:&fetchError];
    if (fetchError) {
        if (error) *error = fetchError;
        return nil;
    }

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:memories.count];
    for (CDMemory *m in memories) {
        NSMutableDictionary *row = [@{
            @"title": m.title ?: @"Untitled",
            @"type": m.type ?: @"memory",
            @"dateCreated": m.dateCreated ? [df stringFromDate:m.dateCreated] : @"",
            @"dateModified": m.dateModified ? [df stringFromDate:m.dateModified] : @""
        } mutableCopy];
        if (includeSummary) {
            row[@"summary"] = m.summary ?: @"";
        }
        [results addObject:row];
    }

    NSMutableArray *orderedIDs = [NSMutableArray arrayWithCapacity:memories.count];
    for (CDMemory *m in memories) {
        [orderedIDs addObject:m.objectID];
    }
    [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeRecent
                                   objectIDs:orderedIDs
                                      scores:nil
                                    originID:nil];

    NSMutableDictionary *response = [@{
        @"count": @(results.count),
        @"results": results,
        @"order": ascending ? @"oldest" : @"newest",
        @"by": byArg
    } mutableCopy];
    if (tagNames) {
        response[@"tags"] = tagNames;
    }
    return response;
}

@end
