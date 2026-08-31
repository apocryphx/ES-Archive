//
//  ESMemoryRevisionsTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_revisions
//  "Revision history, oldest first."
//
//  Storage is full snapshots (a revision is the complete pre-edit state,
//  never a diff — robust against a broken chain). The delta format is a
//  read-time presentation computed with the vendored DiffMatchPatch
//  (ES_Archive/Vendor/DiffMatchPatch): revision k's body diffed against
//  revision k+1's (the last against the current head), which renders the
//  history as one entry per EDIT, each carrying the reason stored on the
//  snapshot that edit created.
//

#import "ESMemoryRevisionsTool.h"
#import "CDMemory.h"
#import "CDMemoryRevision.h"
#import "CDMemoryRevision+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import "DiffMatchPatch.h"
#import "DiffMatchPatchInternals.h"
#import "DMDiff.h"

@implementation ESMemoryRevisionsTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_revisions",
        @"description": @"Revision history, oldest first. format=full (default) returns every snapshot "
                         "with its complete body. format=delta returns one entry per EDIT instead: "
                         "{date, reason, diff, changes} — diff is a compact line-diff ('- ' removed, "
                         "'+ ' added, '@@' between hunks) from that snapshot to the next, the last entry "
                         "diffing against the current body; changes lists metadata field changes (type, "
                         "author, locked, private, dateCreated). Prefer delta when asking how an entry "
                         "evolved — it pairs each change with its reason and skips unchanged text. "
                         "Caveats: appends never create revisions (appended text surfaces in the next "
                         "replace's diff), and summaries are not versioned.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title": @{@"type": @"string", @"description": @"Entry title."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"format": @{@"type": @"string", @"enum": @[@"full", @"delta"], @"description": @"full (default): complete snapshot bodies. delta: one compact line-diff per edit."}
            },
            @"required": @[@"title"]
        }
    };
}

#pragma mark - Delta helpers

/// Compact line-diff between two bodies, rendered for an LLM reader:
/// only changed lines, "- " for removed, "+ " for added, "@@" separating
/// discontiguous hunks. Line-token mode keeps the diff aligned to lines
/// (character-level diffs read as noise). Returns @"" when the bodies match.
static NSString *ESCompactLineDiff(NSString *fromBody, NSString *toBody) {
    NSString *from = fromBody ?: @"";
    NSString *to   = toBody   ?: @"";
    if ([from isEqualToString:to]) return @"";

    NSArray *encoded = diff_linesToCharsForStrings(from, to);
    if (encoded.count < 3) return @"";
    NSArray *diffs = diff_diffsBetweenTexts(encoded[0], encoded[1]);
    if (diffs.count == 0) return @"";
    diff_charsToTokens(&diffs, encoded[2]);

    NSMutableString *out = [NSMutableString string];
    BOOL emitted = NO;
    BOOL pendingSeparator = NO;
    for (DMDiff *d in diffs) {
        if (d.operation == DIFF_EQUAL) {
            if (emitted) pendingSeparator = YES;
            continue;
        }
        if (pendingSeparator) {
            [out appendString:@"@@\n"];
            pendingSeparator = NO;
        }
        NSString *prefix = (d.operation == DIFF_DELETE) ? @"- " : @"+ ";
        NSArray<NSString *> *lines = [d.text componentsSeparatedByString:@"\n"];
        NSUInteger count = lines.count;
        if (count > 0 && lines[count - 1].length == 0) count--;  // trailing-newline artifact
        for (NSUInteger i = 0; i < count; i++) {
            [out appendFormat:@"%@%@\n", prefix, lines[i]];
            emitted = YES;
        }
    }
    return out;
}

/// Human-readable list of metadata changes between two states. Only the
/// fields a revision snapshot actually preserves are compared — summary and
/// language are not versioned, so they cannot be reported here.
static NSArray<NSString *> *ESMetadataChanges(CDMemory *from, CDMemory *to,
                                              NSISO8601DateFormatter *df) {
    NSMutableArray<NSString *> *changes = [NSMutableArray array];

    NSString *(^orDash)(NSString *) = ^(NSString *s) { return s.length > 0 ? s : @"—"; };
    if (!(from.type == to.type || [from.type isEqualToString:to.type ?: @""])) {
        [changes addObject:[NSString stringWithFormat:@"type: %@ → %@", orDash(from.type), orDash(to.type)]];
    }
    if (!(from.author == to.author || [from.author isEqualToString:to.author ?: @""])) {
        [changes addObject:[NSString stringWithFormat:@"author: %@ → %@", orDash(from.author), orDash(to.author)]];
    }
    if (from.locked != to.locked) {
        [changes addObject:to.locked ? @"locked: sealed" : @"locked: unsealed"];
    }
    if (from.private != to.private) {
        [changes addObject:to.private ? @"private: set" : @"private: cleared"];
    }
    // dateCreated only moves on an explicit retrofit — surface it when it does.
    if (from.dateCreated && to.dateCreated &&
        fabs([from.dateCreated timeIntervalSinceDate:to.dateCreated]) > 1.0) {
        [changes addObject:[NSString stringWithFormat:@"dateCreated: %@ → %@",
                            [df stringFromDate:from.dateCreated],
                            [df stringFromDate:to.dateCreated]]];
    }
    return changes;
}

#pragma mark - Execute

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
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];

    // Sort oldest first by dateModified — the moment each snapshot's state
    // last changed, which is strictly increasing across a memory's history.
    // (dateCreated is preserved-original on every snapshot since the
    // dateCreated-retrofit feature, so it no longer orders anything.)
    NSArray<CDMemoryRevision *> *sorted = [memory.revisions.allObjects
        sortedArrayUsingComparator:^NSComparisonResult(CDMemoryRevision *a, CDMemoryRevision *b) {
            NSDate *da = a.dateModified ?: a.dateCreated;
            NSDate *db = b.dateModified ?: b.dateCreated;
            if (!da && !db) return NSOrderedSame;
            if (!da) return NSOrderedAscending;
            if (!db) return NSOrderedDescending;
            return [da compare:db];
        }];

    NSString *format = [arguments[@"format"] isKindOfClass:NSString.class] ? arguments[@"format"] : @"full";

    if ([format isEqualToString:@"delta"]) {
        // One entry per edit: revision k holds the PRE-edit state and the
        // reason of the edit that created it, so diff(rev k → rev k+1) is
        // that edit's effect; the final revision diffs against the head.
        NSMutableArray *edits = [NSMutableArray arrayWithCapacity:sorted.count];
        for (NSUInteger k = 0; k < sorted.count; k++) {
            CDMemoryRevision *from = sorted[k];
            CDMemory *to = (k + 1 < sorted.count) ? sorted[k + 1] : memory;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"date"] = to.dateModified ? [df stringFromDate:to.dateModified] : @"";
            entry[@"reason"] = from.reason ?: @"";

            NSString *diff = ESCompactLineDiff(from.body, to.body);
            if (diff.length > 0) entry[@"diff"] = diff;

            NSArray<NSString *> *changes = ESMetadataChanges(from, to, df);
            if (changes.count > 0) entry[@"changes"] = changes;

            if (!entry[@"diff"] && !entry[@"changes"]) {
                entry[@"changes"] = @[@"(no versioned field changed — e.g. a summary or language update, which snapshots don't preserve)"];
            }
            [edits addObject:entry];
        }
        return @{
            @"title": memory.title ?: @"",
            @"format": @"delta",
            @"currentDateModified": memory.dateModified ? [df stringFromDate:memory.dateModified] : @"",
            @"edits": edits,
            @"count": @(edits.count)
        };
    }

    NSMutableArray *revisions = [NSMutableArray array];
    for (CDMemoryRevision *rev in sorted) {
        [revisions addObject:@{
            @"dateCreated": rev.dateCreated ? [df stringFromDate:rev.dateCreated] : @"",
            @"dateModified": rev.dateModified ? [df stringFromDate:rev.dateModified] : @"",
            @"reason": rev.reason ?: @"",
            @"title": rev.title ?: @"",
            @"body": rev.body ?: @""
        }];
    }

    return @{
        @"title": memory.title ?: @"",
        @"currentDateModified": memory.dateModified ? [df stringFromDate:memory.dateModified] : @"",
        @"revisions": revisions
    };
}

@end
