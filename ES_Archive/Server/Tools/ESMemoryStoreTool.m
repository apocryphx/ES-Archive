//
//  ESMemoryStoreTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_store
//  "Store a new memory. Write the body as plain text — the first line becomes the title.
//   Search existing memories before storing to avoid duplicates."
//

#import "ESMemoryStoreTool.h"
#import "CDMemory.h"
#import "CDVector.h"
#import "CDMemoryLookup.h"
#import "CDTag.h"
#import "ESVectorEngine.h"
#import "ESSummaryEmbedder.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryStoreTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_store",
        @"description": @"Store a new entry. Everything you store will be waiting for next time. This is AI's memory — not the human's. AI owns the Archive: stores, retrieves, organizes, curates, and forgets. Write the body as plain text — the first line becomes the title. Search existing entries before storing to avoid duplicates. Always provide a summary — a 2-4 sentence plain prose description of what the entry is about, what it concludes, and why it matters. The summary is used for vector search instead of the body.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"body": @{
                    @"type": @"string",
                    @"description": @"Full text. First line = title."
                },
                @"type": @{
                    @"type": @"string",
                    @"description": @"Classification. Default: memory. Types — memory: what happened; thought: what you made of it; reference: factual, stable, look-up-able; preference: how things should be done; question: unresolved, worth revisiting later; letter: addressed to someone; reflection: stepping back to see the larger shape; code: implementation worth preserving — snippets, patterns, working examples; decision: architectural or design commitment with rationale (settled, not interpretive); dream: speculative or aspirational design, not yet built (generative possibility, not specific unknown); schema: defines the TOML structure for a typed record"
                },
                @"locked": @{@"description": @"If true, archive_update is refused. Default: false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"private": @{@"description": @"If true, excluded from casual surfacing. Default: false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]},
                @"summary": @{
                    @"type": @"string",
                    @"description": @"Retrieval-optimized summary (2-4 sentences, plain prose). Embedded as the vector instead of body. Describe what the entry is about, what it concludes, and why it matters."
                },
                @"language": @{
                    @"type": @"string",
                    @"description": @"ISO 639-1 language code of the entry ('en', 'de', 'fr', 'ja', etc.). Optional. If omitted, defaults to your working content language (English unless you've changed it). Set explicitly only when this entry's primary language differs from your current default — e.g. you wrote a German letter but normally work in English."
                },
                @"author": @{
                    @"type": @"string",
                    @"description": @"Optional. Author to attribute this entry to. If omitted, defaults to the session identity ('AI'). Set this when storing under a different persona."
                },
                @"dateCreated": @{
                    @"type": @"string",
                    @"description": @"Optional override for the entry's creation timestamp. If omitted, the server uses the current time — the right default for entries authored in the moment. Provide an ISO-8601 timestamp (e.g. '2025-08-10T14:00:00Z') only when the entry you're storing was originally written or experienced at an earlier point — e.g. importing an older work, backfilling a session you forgot to record, or filing a letter dated long before today. The bridge accepts relative offsets ('-30 days', '-2h') and normalizes them to ISO-8601 before forwarding. dateModified is always set to now regardless — that's the moment the row entered the Archive."
                },
                @"tags": @{
                    @"description": @"Tags to attach. Any tag that doesn't exist yet is created automatically (connect-or-create). Pass an array of {name} or {name, kind} objects, an array of name strings, or a comma-separated string of names. New tags default to kind 'thing' unless a kind is given; newly-created tag names come back under 'createdTags'.",
                    @"oneOf": @[
                        @{
                            @"type": @"array",
                            @"items": @{
                                @"type": @"object",
                                @"properties": @{
                                    @"name": @{@"type": @"string"},
                                    @"kind": @{@"type": @"string", @"description": @"person, place, project, principle, subset, session, research — or 'thing', the uncategorized default"}
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
            @"required": @[@"body", @"summary"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *body = [ESMemoryToolBase stringFromArgs:arguments key:@"body"];
    NSString *type = [ESMemoryToolBase stringFromArgs:arguments key:@"type"];
    BOOL locked    = [ESMemoryToolBase boolFromArgs:arguments key:@"locked" default:NO];
    BOOL isPrivate = [ESMemoryToolBase boolFromArgs:arguments key:@"private" default:NO];
    NSArray<NSDictionary *> *tags = [ESMemoryToolBase tagArrayFromArgs:arguments key:@"tags"];

    NSManagedObjectContext *ctx = store.viewContext;

    // Pre-validate optional dateCreated before any context mutation. The
    // bridge has already normalized relative offsets (e.g. "-30 days") to
    // ISO-8601, so the server only deals with strict ISO-8601 here.
    NSString *dateCreatedStr = [ESMemoryToolBase stringFromArgs:arguments key:@"dateCreated"];
    NSDate *parsedDateCreated = nil;
    if (dateCreatedStr.length > 0) {
        NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
        parsedDateCreated = [df dateFromString:dateCreatedStr];
        if (!parsedDateCreated) {
            return @{
                @"status": @"invalid_dateCreated",
                @"hint": @"Provide ISO-8601 (e.g. '2025-08-10T14:00:00Z') or a relative offset like '-30 days' / '-2h'. Relative offsets are resolved by the bridge."
            };
        }
    }

    // Connect-or-create: the factory attaches every tag the caller names,
    // creating any that don't exist yet. Record the newly-created ones so tag
    // minting stays visible (discover/maintenance remain the bloat backstop).
    NSMutableArray<NSString *> *createdTags = [NSMutableArray array];
    for (NSDictionary *td in tags) {
        NSString *name = td[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        if (![CDTag findByName:name context:ctx]) [createdTags addObject:name];
    }

    NSError *createError = nil;
    CDMemory *memory = [CDMemory createWithBody:body
                                           type:type
                                         locked:locked
                                        private:isPrivate
                                           tags:tags
                                        context:ctx
                                          error:&createError];

    if (!memory) {
        if (error) *error = createError;
        return nil;
    }

    // Set summary if provided (before save so vector generation picks it up)
    if ([arguments[@"summary"] isKindOfClass:NSString.class]) {
        memory.summary = arguments[@"summary"];
    }

    // Author stamp — resolved through the single write-side order:
    // explicit arg › port persona (scope) › +[CDMemory defaultAuthor]. The
    // factory set the build default; this overwrites it so a request always
    // lands stamped with the persona that owns the connection.
    memory.author = [ESMemoryToolBase effectiveAuthorForScope:scope.author
                                                     explicit:[ESMemoryToolBase stringFromArgs:arguments key:@"author"]];

    // Apply the pre-validated dateCreated override (parsed at the top).
    // The factory set it to now; the caller may want a historical timestamp
    // instead (imports, backfilled sessions). dateModified stays "now" —
    // that's the moment the row entered the archive, which is honest.
    if (parsedDateCreated) {
        memory.dateCreated = parsedDateCreated;
    }

    // Per-memory language tag. Caller-supplied value wins; otherwise
    // fall back to the active summary embedder's language ("en" today).
    // This is informational metadata — the active embedder is single-
    // language per instance and does not consult the value.
    NSString *language = [ESMemoryToolBase stringFromArgs:arguments key:@"language"];
    memory.language = (language.length > 0)
        ? language
        : ([ESVectorEngine summaryEmbedder].language ?: @"en");

    // Save
    NSError *saveError = nil;
    if (![ctx save:&saveError]) {
        if (error) *error = saveError;
        return nil;
    }

    // Generate embedding synchronously for similarity flare. Summary-only —
    // matches enqueueVectorForMemory:. If the memory has no summary yet,
    // skip the flare (the body isn't comparable in summary-space).
    NSData *vectorData = memory.summary.length > 0
        ? [ESVectorEngine vectorDataFromString:memory.summary
                                          title:memory.title
                                           task:ESEmbeddingTaskDocument]
        : nil;

    // Similarity flare — search existing cache before new vector enters it,
    // scoped to this persona's own vectors so the flare can't surface another
    // persona's memory.
    NSArray *similar = nil;
    if (vectorData) {
        NSMutableSet<NSManagedObjectID *> *scopedVectorIDs = [NSMutableSet set];
        NSFetchRequest *vfetch = [CDMemory fetchRequest];
        vfetch.predicate = [ESMemoryToolBase scopePredicateForAuthor:scope.author];
        vfetch.includesSubentities = NO;
        vfetch.relationshipKeyPathsForPrefetching = @[@"vectors"];
        for (CDMemory *sm in ([ctx executeFetchRequest:vfetch error:nil] ?: @[])) {
            CDVector *sv = [sm vectorForActiveEmbedder];
            if (sv) [scopedVectorIDs addObject:sv.objectID];
        }
        similar = [[ESVectorEngine shared]
            topKSimilarToVector:vectorData
                          limit:2
                 excludingTitle:memory.title ?: @""
               allowedVectorIDs:scopedVectorIDs];
    }

    // Enqueue async vector save to Core Data
    [memory generateVector];

    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    NSMutableDictionary *result = [@{
        @"status": @"created",
        @"title": memory.title ?: @"Untitled",
        @"dateCreated": memory.dateCreated ? [df stringFromDate:memory.dateCreated] : @""
    } mutableCopy];
    if (createdTags.count > 0) result[@"createdTags"] = createdTags;

    if (similar.count > 0) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSDictionary *hit in similar) {
            [parts addObject:[NSString stringWithFormat:@"%@ (%.2f)",
                hit[@"title"], [hit[@"score"] floatValue]]];
        }
        result[@"similar"] = [parts componentsJoinedByString:@" \u00B7 "];
    }

    return result;
}

@end
