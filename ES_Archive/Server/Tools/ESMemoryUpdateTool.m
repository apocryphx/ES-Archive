//
//  ESMemoryUpdateTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_update
//  "Revise an existing memory. Previous version preserved automatically.
//   Locked memories are read-only until the flag is reset."
//
//  CRITICAL: When creating a revision, copy ALL fields from the head memory before overwriting.
//  A revision is a complete snapshot — not a diff.
//

#import "ESMemoryUpdateTool.h"
#import "CDMemory.h"
#import "CDMemoryRevision.h"
#import "CDMemoryRevision+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import "CDTag.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryUpdateTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_update",
        @"description": @"Revise an existing entry. Previous version preserved automatically. "
                         "Locked entries are read-only and refuse edits until you reset the flag — pass "
                         "locked:false to unlock (you may unlock and edit in the same call). "
                         "Body is OPTIONAL: omit it for a metadata-only update (unlock, retype, dateCreated "
                         "retrofit) which leaves body and title untouched; provide it to replace the body, in "
                         "which case the title is re-derived from line 1. On a body replace without a fresh "
                         "summary the existing summary is RETAINED (never cleared — the summary is the only text "
                         "embedded for vector search, so clearing would de-index the entry); minor edits need no "
                         "new summary, but provide one whenever the meaning changed, or retrieval goes stale — the "
                         "response notes when the retained summary may no longer match. "
                         "Pass append=true to concatenate the body to the "
                         "existing body (joined with a newline) instead of replacing it; on append no revision "
                         "is created, the existing summary is retained unless a new one is provided, and reason is ignored.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"title": @{@"type": @"string", @"description": @"Title to update."},
                @"author": @{@"type": @"string", @"description": @"Disambiguation."},
                @"newAuthor": @{@"type": @"string", @"description": @"Optional. Replace the entry's author field with this value (in place; the prior author is preserved on the revision snapshot). Distinct from 'author', which only disambiguates which entry to update. (Legacy spelling new_author is still accepted.)"},
                @"index": @{@"description": @"Disambiguation index from ambiguous response.", @"oneOf": @[@{@"type": @"integer"}, @{@"type": @"string"}]},
                @"body": @{@"type": @"string", @"description": @"New body text (optional). Omit to leave the body and title unchanged — a metadata-only update. When append=true, this is the delta to concatenate to the existing body."},
                @"reason": @{@"type": @"string", @"description": @"Optional. Why this revision — stored on the revision snapshot. Ignored when append=true (no revision is created)."},
                @"append": @{@"description": @"When true, body is appended to the existing body (joined with a single newline) instead of replacing it. No revision is created. Summary is retained unless explicitly replaced. dateModified is updated. Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"type": @{@"type": @"string", @"description": @"Update classification."},
                @"locked": @{@"description": @"Read-only flag. Pass false to reset it — the one edit a locked entry always permits, and it may be combined with other changes in the same call. Pass true to seal.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"private": @{@"description": @"Change private.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"summary": @{@"type": @"string", @"description": @"Retrieval-optimized summary (2-4 sentences, plain prose). Embedded as the vector instead of body. Describe what the entry is about, what it concludes, and why it matters."},
                @"language": @{@"type": @"string", @"description": @"ISO 639-1 language code of the updated entry ('en', 'de', etc.). Optional. If omitted, the entry's existing language tag is preserved. Set explicitly only when you're actually changing the language of the entry's primary content."},
                @"dateCreated": @{@"type": @"string", @"description": @"Optional retrofit of the historical creation timestamp. ISO-8601 ('2025-08-10T14:00:00Z') or a relative offset (the bridge normalizes '-30 days' → ISO-8601). Use this to correct an entry whose creation date is wrong — typically because the entry was imported or bulk re-saved and lost its original authoring date. dateModified always updates to now (this IS a modification); the previous values of both dateCreated and dateModified are preserved on the revision snapshot."},
                @"tags": @{
                    @"type": @"array",
                    @"description": @"Replace tags.",
                    @"items": @{
                        @"type": @"object",
                        @"properties": @{
                            @"name": @{@"type": @"string"},
                            @"kind": @{@"type": @"string"}
                        },
                        @"required": @[@"name"]
                    }
                }
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

    CDMemory *memory = lookup.memory;

    NSString *bodyArg = [ESMemoryToolBase stringFromArgs:arguments key:@"body"];
    BOOL append = [ESMemoryToolBase boolFromArgs:arguments key:@"append" default:NO];

    // Lock behaves like a file's read-only flag: a locked memory refuses edits
    // until the flag is reset. The one change always permitted is resetting the
    // flag itself — pass locked:false to unlock. Unlock-and-edit in the same
    // call is allowed because passing locked:false is a deliberate act; an
    // update that never mentions the flag cannot accidentally slip past it.
    if (memory.locked) {
        BOOL resettingFlag = (arguments[@"locked"] != nil) &&
                             ![ESMemoryToolBase boolFromArgs:arguments key:@"locked" default:YES];
        if (!resettingFlag) {
            return @{
                @"status": @"locked",
                @"title": memory.title ?: @"",
                @"hint": @"Locked (read-only). Pass locked:false to reset the flag; you may unlock and edit in the same call."
            };
        }
    }

    // Append requires non-empty body content (it's the delta to concatenate).
    if (append && bodyArg.length == 0) {
        return @{
            @"status": @"invalid_append",
            @"title": memory.title ?: @"",
            @"hint": @"append=true requires non-empty body content."
        };
    }

    // Pre-validate optional dateCreated before any context mutation. Same
    // discipline as the tags pre-validation below: parse failures must
    // bail out before we touch the context. Bridge has already normalized
    // any relative offset to ISO-8601.
    NSString *dateCreatedStr = [ESMemoryToolBase stringFromArgs:arguments key:@"dateCreated"];
    NSDate *parsedDateCreated = nil;
    if (dateCreatedStr.length > 0) {
        NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
        parsedDateCreated = [df dateFromString:dateCreatedStr];
        if (!parsedDateCreated) {
            return @{
                @"status": @"invalid_dateCreated",
                @"title": memory.title ?: @"",
                @"hint": @"Provide ISO-8601 (e.g. '2025-08-10T14:00:00Z') or a relative offset like '-30 days' / '-2h'. Relative offsets are resolved by the bridge."
            };
        }
    }

    // Pre-validate tags (if provided) before mutating anything. Strict:
    // every named tag must already exist. Done up front so the revision
    // insert and field updates aren't left pending in the context if the
    // caller passed an unknown tag.
    NSArray<CDTag *> *resolvedTags = nil;
    if (arguments[@"tags"]) {
        NSArray<NSDictionary *> *tagDicts = [ESMemoryToolBase tagArrayFromArgs:arguments key:@"tags"];
        NSMutableArray<NSString *> *missing = [NSMutableArray array];
        NSMutableArray<CDTag *> *resolved = [NSMutableArray array];
        for (NSDictionary *td in tagDicts) {
            NSString *name = td[@"name"];
            if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
            CDTag *tag = [CDTag findByName:name context:ctx];
            if (tag) [resolved addObject:tag];
            else [missing addObject:name];
        }
        if (missing.count > 0) {
            return @{
                @"status": @"missing_tags",
                @"title": memory.title ?: @"",
                @"missing": missing,
                @"hint": @"Create tags first via archive_tags (mode=create, name, kind)."
            };
        }
        resolvedTags = resolved;
    }

    // Create revision snapshot — copy ALL fields from head memory.
    // Skipped on append: accumulation is forward-only, not revision.
    if (!append) {
        CDMemoryRevision *revision = [NSEntityDescription insertNewObjectForEntityForName:@"CDMemoryRevision"
                                                                   inManagedObjectContext:ctx];
        revision.uuid = [NSUUID UUID];
        revision.title = memory.title;
        revision.author = memory.author;
        revision.body = memory.body;
        revision.type = memory.type;
        revision.locked = memory.locked;
        revision.private = memory.private;
        revision.dateCreated = memory.dateCreated;
        revision.dateModified = memory.dateModified;
        revision.dateAccessed = memory.dateAccessed;
        revision.accessCount = memory.accessCount;
        revision.reason = arguments[@"reason"] ?: @"";
        revision.memory = memory;
    }

    // Update head memory. On append, concatenate with a single newline (caller
    // owns any internal structure). On replace, swap in the new body and
    // re-derive the title from line 1. Omitting body makes this a metadata-only
    // update — the body and title are left intact (no title re-extraction, so a
    // TOML-fronted import keeps its title).
    if (append) {
        NSString *existing = memory.body ?: @"";
        memory.body = [existing stringByAppendingFormat:@"\n%@", bodyArg];
    } else if (bodyArg.length > 0) {
        memory.body = bodyArg;
        [memory extractTitleFromBody];
    }
    memory.dateModified = [NSDate now];

    NSString *typeArg = [ESMemoryToolBase stringFromArgs:arguments key:@"type"];
    if (typeArg) {
        memory.type = typeArg;
    }
    if (arguments[@"locked"] != nil) {
        memory.locked = [ESMemoryToolBase boolFromArgs:arguments key:@"locked" default:memory.locked];
    }
    if (arguments[@"private"] != nil) {
        memory.private = [ESMemoryToolBase boolFromArgs:arguments key:@"private" default:memory.private];
    }

    // Author rewrite — the revision snapshot above already captured the prior
    // author, so the change is recoverable. Empty/missing falls through.
    NSString *newAuthor = [ESMemoryToolBase stringFromArgs:arguments key:@"newAuthor"]
                       ?: [ESMemoryToolBase stringFromArgs:arguments key:@"new_author"];
    if (newAuthor) {
        memory.author = newAuthor;
    }

    // Update summary when provided. A body REPLACE without a fresh summary
    // RETAINS the existing one — minor edits (typo fixes, small corrections)
    // shouldn't demand re-summarizing. It is never cleared: the summary is
    // the ONLY text that feeds the vector (ESVectorEngine: no summary ⇒ no
    // vector), so a clear would silently de-index the memory. The trade-off
    // is staleness after a substantive rewrite, so the response carries a
    // note when the retained summary may no longer match the body.
    if ([arguments[@"summary"] isKindOfClass:NSString.class]) {
        memory.summary = arguments[@"summary"];
    }

    // Update language: only when caller provides a value. Unlike summary,
    // language usually stays stable across body edits (a user editing a
    // German memory keeps it German); preserving the existing tag is the
    // right default. Claude passes language explicitly only when the
    // memory's primary language has actually changed.
    NSString *languageArg = [ESMemoryToolBase stringFromArgs:arguments key:@"language"];
    if (languageArg.length > 0) {
        memory.language = languageArg;
    }

    // Apply the pre-validated dateCreated retrofit. The revision snapshot
    // above already captured the prior dateCreated, so the historical edit
    // is recoverable. dateModified stays at the [NSDate now] set earlier.
    if (parsedDateCreated) {
        memory.dateCreated = parsedDateCreated;
    }

    // Replace tags if provided (already validated above).
    if (resolvedTags) {
        [memory removeTags:memory.tags];
        for (CDTag *tag in resolvedTags) {
            [memory addTagsObject:tag];
        }
    }

    // Save
    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        if (error) *error = saveError;
        return nil;
    }

    // The vector is embedded as "title: {title} | text: {summary}" — ONLY the
    // title and summary feed it. So re-embed exactly when one of those two can
    // change:
    //   - summary provided → summary changed;
    //   - body REPLACE → re-derives the title from line 1 (the summary is
    //     retained when no fresh one is given, so the vector may be
    //     unchanged — the re-embed is cheap and keeps the condition simple).
    // Everything else leaves the vector identical: an append concatenates to
    // the end (title's first line and summary both untouched), and a
    // metadata-only update (retype, unlock, dateCreated, tags) touches neither.
    // Re-embedding those would be wasted work — and the previous condition,
    // gated on body changes but not summary changes, missed the summary-only
    // update entirely, leaving the memory unsearchable until a launch backfill.
    BOOL summaryProvided = [arguments[@"summary"] isKindOfClass:NSString.class];
    BOOL bodyReplaced    = (!append && bodyArg.length > 0);
    if (summaryProvided || bodyReplaced) {
        [memory generateVector];
    }

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSMutableDictionary *response = [@{
        @"status": @"updated",
        @"title": memory.title ?: @"",
        @"revisions": @(memory.revisions.count),
        @"dateModified": memory.dateModified ? [df stringFromDate:memory.dateModified] : @""
    } mutableCopy];

    // Surface the summary situation on a body replace without a fresh summary:
    // fine for minor edits, but after a substantive rewrite the retained
    // summary — the only text vector search sees — no longer describes the
    // body. If there is no summary at all, the memory is invisible to
    // archive_search entirely.
    if (bodyReplaced && !summaryProvided) {
        if (memory.summary.length > 0) {
            response[@"note"] = @"Existing summary retained. If this edit changed the entry's meaning, follow up with a fresh summary — vector search sees only the summary, not the body.";
        } else {
            response[@"note"] = @"This entry has no summary and is invisible to vector search. Provide one (2-4 sentences, plain prose) to make it findable.";
        }
    }
    return response;
}

@end
