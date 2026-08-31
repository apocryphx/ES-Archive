//
//  ESMemoryGrepTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_grep
//
//  Line-addressed pattern search across a memory's body.
//  Always compiles a regex (literal mode escapes via NSRegularExpression
//  escapedPatternForString:). Body line 1 is always the title.
//

#import "ESMemoryGrepTool.h"
#import "CDMemory.h"
#import "CDMemoryLookup.h"
#import "CDTag.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryGrepTool

#pragma mark - Schema

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_grep",
        @"description": @"grep over entry bodies — returns the matching lines with line numbers, entry_title, and surrounding context, not whole-entry summaries. The exact-string counterpart to `archive_search`: reach for it when you know the literal text and want the passage it sits in — proper nouns, identifiers or code, an exact phrase, quoting an entry verbatim, or finding every place a term appears across the Archive. `archive_search` finds the idea; `archive_grep` finds the string. Two modes: single-entry (pass `title` to drill into one) and corpus-wide (omit `title` to scan every body, optionally pre-filtered by `tags`). Literal substring by default; set `regex:true` for ICU regex; `output_mode` switches between snippets, a matching-entry list, and a count. Line 1 of every body is always the title. To search the *content* of a referenced document, resolve its handle and grep the file directly.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title":            @{@"type": @"string", @"description": @"Entry title. Omit to search the entire corpus."},
                @"author":           @{@"type": @"string", @"description": @"Disambiguation. Single-entry mode only."},
                @"index":            @{@"description": @"Disambiguation index from ambiguous response. Single-entry mode only.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"tags":             @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": @"Restrict corpus search to entries carrying ANY of these tags (OR semantics, case-insensitive). Ignored when `title` is provided."},
                @"pattern":          @{@"type": @"string", @"description": @"Substring or ICU regex."},
                @"regex":            @{@"description": @"Treat pattern as ICU regex. Default false (literal substring).", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"case_sensitive":   @{@"description": @"Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"multiline":        @{@"description": @"`.` matches newlines and `^`/`$` match line boundaries. Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"output_mode":      @{@"type": @"string", @"enum": @[@"content", @"files_with_matches", @"count"], @"description": @"Default content. In corpus mode, files_with_matches is the discovery shape — one row per (entry,source) with a hit."},
                @"context_lines":    @{@"description": @"Lines of context before/after each match. 0–10. Default 2. Only used in content mode.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"head_limit":       @{@"description": @"Max entries returned. Default 100, max 1000.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"offset":           @{@"description": @"Skip this many matches before applying head_limit. Default 0.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]}
            },
            @"required": @[@"pattern"]
        }
    };
}

#pragma mark - File-local helpers

// Build line-start offsets for `text`. Index 0 is the start of line 1.
// A sentinel equal to text.length is appended so LineContent can compute
// the last line's end without bounds checks.
static NSArray<NSNumber *> *BuildLineStarts(NSString *text) {
    NSUInteger length = text.length;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray arrayWithCapacity:MAX((NSUInteger)16, length / 40)];
    [starts addObject:@(0)];
    NSUInteger i = 0;
    while (i < length) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n') {
            [starts addObject:@(i + 1)];
        }
        i++;
    }
    [starts addObject:@(length)]; // sentinel
    return starts;
}

// Binary-search the line-start array for the 1-indexed line containing `offset`.
// `starts` has lineCount + 1 entries (last is sentinel = text.length).
static NSUInteger LineForOffset(NSArray<NSNumber *> *starts, NSUInteger offset) {
    NSUInteger lo = 0;
    NSUInteger hi = starts.count - 1; // exclude sentinel from search range
    while (lo + 1 < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if ([starts[mid] unsignedIntegerValue] <= offset) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo + 1; // 1-indexed
}

// Slice the content of 1-indexed line `lineIdx` (without trailing newline).
static NSString *LineContent(NSString *text, NSArray<NSNumber *> *starts, NSUInteger lineIdx) {
    NSUInteger lineCount = starts.count - 1; // exclude sentinel
    if (lineIdx < 1 || lineIdx > lineCount) return @"";
    NSUInteger start = [starts[lineIdx - 1] unsignedIntegerValue];
    NSUInteger end   = [starts[lineIdx] unsignedIntegerValue];
    if (end > start && [text characterAtIndex:end - 1] == '\n') {
        end--;
    }
    if (end <= start) return @"";
    return [text substringWithRange:NSMakeRange(start, end - start)];
}

#pragma mark - Execute

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    // ---- Parameter resolution -----------------------------------------------
    NSString *pattern = arguments[@"pattern"];
    if (![pattern isKindOfClass:[NSString class]] || pattern.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey: @"pattern is required"}];
        }
        return nil;
    }

    BOOL useRegex      = [ESMemoryToolBase boolFromArgs:arguments key:@"regex" default:NO];
    BOOL caseSensitive = [ESMemoryToolBase boolFromArgs:arguments key:@"case_sensitive" default:NO];
    BOOL multiline     = [ESMemoryToolBase boolFromArgs:arguments key:@"multiline" default:NO];

    NSString *outputMode = [ESMemoryToolBase stringFromArgs:arguments key:@"output_mode"];
    if (!outputMode) outputMode = @"content";
    if (![@[@"content", @"files_with_matches", @"count"] containsObject:outputMode]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Invalid output_mode: '%@'", outputMode]}];
        }
        return nil;
    }

    NSInteger contextLines = [ESMemoryToolBase integerFromArgs:arguments key:@"context_lines" default:2];
    if (contextLines < 0) contextLines = 0;
    if (contextLines > 10) contextLines = 10;

    NSInteger headLimit = [ESMemoryToolBase integerFromArgs:arguments key:@"head_limit" default:100];
    if (headLimit < 1) headLimit = 1;
    if (headLimit > 1000) headLimit = 1000;

    NSInteger offset = [ESMemoryToolBase integerFromArgs:arguments key:@"offset" default:0];
    if (offset < 0) offset = 0;

    // ---- Compile regex ------------------------------------------------------
    NSString *effectivePattern = useRegex ? pattern : [NSRegularExpression escapedPatternForString:pattern];
    NSRegularExpressionOptions regexOpts = 0;
    if (!caseSensitive) regexOpts |= NSRegularExpressionCaseInsensitive;
    if (multiline)      regexOpts |= NSRegularExpressionDotMatchesLineSeparators | NSRegularExpressionAnchorsMatchLines;

    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:effectivePattern
                                                                           options:regexOpts
                                                                             error:&regexError];
    if (!regex) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"Invalid regex: %@", regexError.localizedDescription]}];
        }
        return nil;
    }

    // Mode selection: title provided → single-memory; absent → corpus.
    NSString *titleArg = [ESMemoryToolBase stringFromArgs:arguments key:@"title"];
    BOOL corpusMode = (titleArg.length == 0);

    // Tag filter (corpus mode only).
    NSArray *rawTags = [ESMemoryToolBase arrayFromArgs:arguments key:@"tags"];
    NSMutableArray<NSString *> *tagNames = nil;
    if (corpusMode && rawTags) {
        tagNames = [NSMutableArray array];
        for (id name in rawTags) {
            if ([name isKindOfClass:NSString.class] && [(NSString *)name length] > 0) {
                [tagNames addObject:(NSString *)name];
            }
        }
        if (tagNames.count == 0) tagNames = nil;
    }

    // ---- Pull strings on main queue ----------------------------------------
    __block CDMemoryLookupResult *lookup = nil;
    __block NSString *memoryTitle = nil;              // single-mode only
    __block NSManagedObjectID *memoryObjectID = nil;  // single-mode only
    __block NSMutableArray<NSDictionary *> *targets = [NSMutableArray array];
    // Each target: {entry_title, archive_objectID, source, text}
    __block BOOL tagsUnresolved = NO;
    __block NSUInteger corpusMemoryCount = 0;

    dispatch_block_t mainBlock = ^{
        NSManagedObjectContext *ctx = store.viewContext;

        // Collect source memories.
        NSArray<CDMemory *> *sources = nil;

        if (!corpusMode) {
            lookup = [CDMemoryLookup findScopedMemoryWithTitle:titleArg
                                                   scopeAuthor:scope.author
                                                 disambiguator:arguments[@"author"]
                                                         index:arguments[@"index"]
                                                       context:ctx];
            if (lookup.status != CDMemoryLookupFound) return;
            sources = @[lookup.memory];
            memoryTitle = lookup.memory.title ?: @"Untitled";
            memoryObjectID = lookup.memory.objectID;
        } else {
            // Resolve optional tag filter (same two-pass pattern as archive_search/recent).
            NSMutableArray<CDTag *> *resolvedTags = nil;
            if (tagNames) {
                resolvedTags = [NSMutableArray array];
                for (NSString *name in tagNames) {
                    CDTag *tag = [CDTag findByName:name context:ctx];
                    // Skip expired tags, mirroring lfind's default — an expired
                    // working-set tag shouldn't silently scope a grep.
                    BOOL live = tag && (!tag.dateExpired ||
                                        [tag.dateExpired compare:[NSDate now]] != NSOrderedAscending);
                    if (live) [resolvedTags addObject:tag];
                }
                if (resolvedTags.count == 0) {
                    tagsUnresolved = YES;
                    return;
                }
            }

            NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
            fetch.includesSubentities = NO;
            // Persona scope first, then the optional tag filter.
            NSMutableArray<NSPredicate *> *gPreds = [NSMutableArray array];
            [gPreds addObject:[ESMemoryToolBase scopePredicateForAuthor:scope.author]];
            if (resolvedTags) {
                [gPreds addObject:[NSPredicate predicateWithFormat:@"ANY tags IN %@", resolvedTags]];
            }
            fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:gPreds];
            fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];

            NSError *fetchError = nil;
            sources = [ctx executeFetchRequest:fetch error:&fetchError];
            if (fetchError || !sources) sources = @[];
            corpusMemoryCount = sources.count;
        }

        for (CDMemory *memory in sources) {
            if (memory.body.length == 0) continue;
            [targets addObject:@{
                @"entry_title":    memory.title ?: @"Untitled",
                @"archive_objectID": memory.objectID,
                @"source":          @"body",
                @"text":            [memory.body copy]
            }];
        }
    };

    if ([NSThread isMainThread]) {
        mainBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), mainBlock);
    }

    if (!corpusMode) {
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
    } else if (tagsUnresolved) {
        return @{
            @"status":       @"ok",
            @"mode":         @"corpus",
            @"pattern":      pattern,
            @"tags":         tagNames ?: @[],
            @"match_count":  @0,
            @"results":      @[],
            @"note":         @"No entries carry any of the requested tags."
        };
    }

    // ---- Pass 1: find matches per target (off-main, immutable strings) -----
    // Each per-target record: {source, text, lineStarts, lines: [{line, line_end?}]}
    NSMutableArray<NSDictionary *> *perTarget = [NSMutableArray arrayWithCapacity:targets.count];
    NSUInteger totalMatches = 0;

    for (NSDictionary *target in targets) {
        NSString *text = target[@"text"];
        NSArray<NSNumber *> *starts = BuildLineStarts(text);

        NSMutableArray<NSDictionary *> *lines = [NSMutableArray array];
        NSUInteger lastLine = 0;

        NSArray<NSTextCheckingResult *> *hits = [regex matchesInString:text
                                                               options:0
                                                                 range:NSMakeRange(0, text.length)];
        for (NSTextCheckingResult *hit in hits) {
            NSRange r = hit.range;
            if (r.length == 0) continue;
            NSUInteger lineStart = LineForOffset(starts, r.location);
            if (lineStart == lastLine) continue; // collapse multi-hit lines
            lastLine = lineStart;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"line"] = @(lineStart);
            if (multiline && r.length > 0) {
                NSUInteger lineEnd = LineForOffset(starts, r.location + r.length - 1);
                if (lineEnd > lineStart) {
                    entry[@"line_end"] = @(lineEnd);
                }
            }
            [lines addObject:entry];
        }

        totalMatches += lines.count;
        [perTarget addObject:@{
            @"entry_title":    target[@"entry_title"],
            @"archive_objectID": target[@"archive_objectID"],
            @"source":          target[@"source"],
            @"text":            text,
            @"lineStarts":      starts,
            @"lines":           lines
        }];
    }

    // ---- Aggregate per output_mode -----------------------------------------
    NSMutableDictionary *envelope = [NSMutableDictionary dictionary];
    envelope[@"status"]       = @"ok";
    envelope[@"mode"]         = corpusMode ? @"corpus" : @"single";
    if (!corpusMode) envelope[@"entry_title"] = memoryTitle;
    if (corpusMode)  envelope[@"scanned_memories"] = @(corpusMemoryCount);
    if (tagNames)    envelope[@"tags"] = tagNames;
    envelope[@"pattern"]      = pattern;
    envelope[@"regex"]        = @(useRegex);
    envelope[@"multiline"]    = @(multiline);
    envelope[@"output_mode"]  = outputMode;
    envelope[@"match_count"]  = @(totalMatches);

    if ([outputMode isEqualToString:@"count"]) {
        NSMutableArray *results = [NSMutableArray arrayWithCapacity:perTarget.count];
        for (NSDictionary *t in perTarget) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            if (corpusMode) row[@"entry_title"] = t[@"entry_title"];
            row[@"source"]      = t[@"source"];
            row[@"match_count"] = @([t[@"lines"] count]);
            [results addObject:row];
        }
        envelope[@"truncated"] = @NO;
        envelope[@"results"]   = results;
    } else if ([outputMode isEqualToString:@"files_with_matches"]) {
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *t in perTarget) {
            NSUInteger count = [t[@"lines"] count];
            if (count == 0) continue;
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            if (corpusMode) row[@"entry_title"] = t[@"entry_title"];
            row[@"source"]      = t[@"source"];
            row[@"match_count"] = @(count);
            [results addObject:row];
        }
        envelope[@"truncated"] = @NO;
        envelope[@"results"]   = results;
    } else {
        // content mode — flatten across targets, apply offset/head_limit, then slice
        NSMutableArray *flat = [NSMutableArray arrayWithCapacity:totalMatches];
        for (NSDictionary *t in perTarget) {
            for (NSDictionary *line in t[@"lines"]) {
                [flat addObject:@{@"target": t, @"line": line}];
            }
        }

        NSUInteger sliceStart = (NSUInteger)offset;
        if (sliceStart > flat.count) sliceStart = flat.count;
        NSUInteger sliceEnd = sliceStart + (NSUInteger)headLimit;
        if (sliceEnd > flat.count) sliceEnd = flat.count;

        NSMutableArray *results = [NSMutableArray arrayWithCapacity:sliceEnd - sliceStart];
        for (NSUInteger i = sliceStart; i < sliceEnd; i++) {
            NSDictionary *flatItem = flat[i];
            NSDictionary *t = flatItem[@"target"];
            NSDictionary *line = flatItem[@"line"];
            NSString *text = t[@"text"];
            NSArray<NSNumber *> *starts = t[@"lineStarts"];
            NSUInteger lineCount = starts.count - 1;
            NSUInteger lineNo = [line[@"line"] unsignedIntegerValue];

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            if (corpusMode) entry[@"entry_title"] = t[@"entry_title"];
            entry[@"source"] = t[@"source"];
            entry[@"line"]   = line[@"line"];
            if (line[@"line_end"]) entry[@"line_end"] = line[@"line_end"];
            entry[@"content"] = LineContent(text, starts, lineNo);

            if (contextLines > 0) {
                NSMutableArray *before = [NSMutableArray array];
                for (NSInteger d = contextLines; d >= 1; d--) {
                    NSInteger ln = (NSInteger)lineNo - d;
                    if (ln >= 1) [before addObject:LineContent(text, starts, (NSUInteger)ln)];
                }
                NSMutableArray *after = [NSMutableArray array];
                for (NSInteger d = 1; d <= contextLines; d++) {
                    NSUInteger ln = lineNo + (NSUInteger)d;
                    if (ln <= lineCount) [after addObject:LineContent(text, starts, ln)];
                }
                entry[@"context_before"] = before;
                entry[@"context_after"]  = after;
            }

            [results addObject:entry];
        }

        envelope[@"truncated"] = @(sliceEnd < flat.count);
        envelope[@"results"]   = results;
    }

    // ---- Access notification -----------------------------------------------
    // Post for every memory that had at least one match.
    NSMutableOrderedSet<NSManagedObjectID *> *hitIDs = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *t in perTarget) {
        if ([t[@"lines"] count] == 0) continue;
        NSManagedObjectID *oid = t[@"archive_objectID"];
        if (oid) [hitIDs addObject:oid];
    }
    if (hitIDs.count > 0) {
        NSMutableArray *scores = [NSMutableArray arrayWithCapacity:hitIDs.count];
        for (NSUInteger i = 0; i < hitIDs.count; i++) [scores addObject:@(1.0)];
        [ESMemoryToolBase postAccessNotification:ESMemoryAccessTypeRead
                                       objectIDs:[hitIDs array]
                                          scores:scores
                                        originID:nil];
    }

    return envelope;
}

@end
