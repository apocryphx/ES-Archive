//
//  ESMemoryMaintenanceTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_maintenance
//  Status (no params) and bulk actions (backfill /
//  reindexSummaries / erase / clean / pruneTags / dedupeTags / dedupeEntries /
//  dedupeEmbedders). Each call does one thing.
//

#import "ESMemoryMaintenanceTool.h"
#import "ESVectorEngine.h"
#import "ESSummaryEmbedder.h"
#import "ESMemoryToolBase.h"
#import "ESCoreDataStack.h"
#import "ESDedupeMergeCore.h"
#import "CDTag.h"
#import "ESTagJanitor.h"
#import "CDTag+CoreDataProperties.h"
#import "CDEmbedder.h"
#import "CDLink.h"
#import "CDMarginalia.h"
#import "CDMemory.h"
#import "CDMemoryRevision.h"
#import "CDReference.h"
#import "CDVector.h"

@implementation ESMemoryMaintenanceTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_maintenance",
        @"description":
            @"Control panel for the summary embedder and Archive housekeeping. Two modes:\n\n"
            @"1. STATUS — call with no parameters. Returns active embedder, Archive counts "
            @"(entryCount, activeVectorCount, entriesWithoutActiveVector), pending vector ops, "
            @"and the stale-vector report. Always safe.\n\n"
            @"2. ACTIONS — set `action` to one of:\n"
            @"   - `backfill`: encode summaries for entries that lack a vector under the active "
            @"embedder. Additive, safe to run anytime, runs in background. Returns immediately with "
            @"status \"backfill_started\"; poll `pendingVectorOperations` until 0.\n"
            @"   - `reindexSummaries`: synchronously delete every CDVector and re-encode every "
            @"entry's summary under the active embedder. Destructive; use after schema drift or "
            @"calibration changes. Returns when the reindex completes.\n"
            @"   - `erase`: synchronously delete every vector owned by the active embedder. "
            @"Destructive and irreversible. Run before `backfill` for a full re-embed.\n"
            @"   - `clean`: remove dead weight in one pass — stale vectors (not produced by the "
            @"active embedder) and empty entries (no body and no summary, skipping locked). "
            @"Synchronous; returns counts and identifiers/titles of what was removed.\n"
            @"   - `pruneTags`: hard-delete ephemeral tags whose `dateExpired` passed more than "
            @"`graceDays` ago (default 7). Expiry already hides them from every query; this reclaims "
            @"the dead rows so they stop syncing. Synchronous and independent of vector state.\n"
            @"   - `dedupeTags`: reconcile same-name tag duplicates (which CloudKit can leave across "
            @"devices, since name-uniqueness is enforced only at creation). Groups tags by case- and "
            @"diacritic-folded name; for each collision it keeps one canonical (most memberships, then "
            @"permanent, then oldest), moves the others' memberships onto it, and deletes them. "
            @"Synchronous and independent of vector state.\n"
            @"   - `dedupeEntries`: merge byte-identical duplicate entries (same title, body, and "
            @"author) left by historical double-writes and backdated re-imports. The oldest copy "
            @"survives with its original dateCreated; the duplicates' tags, links, comments, "
            @"references, revision history, and access stats fold onto it before they are deleted. "
            @"Locked duplicates merge too — the surviving copy is kept locked, so a seal is never "
            @"lost (locking guards against edits, not against collapsing a byte-identical CloudKit "
            @"twin). Pass `dryRun: true` to get the full merge plan without changing anything "
            @"— always dry-run first.\n"
            @"   - `dedupeEmbedders`: reconcile duplicate embedder inventory rows for the same model "
            @"identifier (CloudKit can leave several; vectors then scatter across them). The row with "
            @"the most vectors survives, every other row's vectors are re-pointed onto it, and the "
            @"emptied rows are deleted. Retrieval is identifier-based and unaffected either way.\n\n"
            @"Every action except pruneTags and dedupeTags (pure tag-store ops) refuses with status "
            @"\"action_refused\" while `pendingVectorOperations > 0` — that includes dedupeEntries "
            @"and dedupeEmbedders, which fold or re-point vectors. "
            @"Wait for pending to reach zero, then retry.",
        @"annotations": @{
            @"readOnlyHint":    @NO,
            @"destructiveHint": @YES,
            @"idempotentHint":  @YES,
        },
        @"inputSchema": @{
            @"type": @"object",
            @"additionalProperties": @NO,
            @"properties": @{
                @"action": @{
                    @"type": @"string",
                    @"description": @"Bulk operation to fire. `backfill` = encode summaries for entries missing the active vector (background). `reindexSummaries` = wipe + re-encode every entry's summary under the active embedder (synchronous). `erase` = delete all active-embedder vectors (synchronous). `clean` = remove stale vectors + empty entries (synchronous). `pruneTags` = hard-delete ephemeral tags expired more than `graceDays` ago. `dedupeTags` = merge same-name tag duplicates left by CloudKit sync. (Both tag actions are synchronous and independent of vector state.)",
                    @"enum": @[@"backfill", @"reindexSummaries", @"erase", @"clean", @"pruneTags", @"dedupeTags", @"dedupeEntries", @"dedupeEmbedders"],
                },
                @"graceDays": @{
                    @"type": @"integer",
                    @"description": @"pruneTags only: keep expired tags this many days past dateExpired before hard-deleting, so they stay visible to --include-expired in the interim. Default 7. Use 0 to prune everything already expired.",
                },
                @"dryRun": @{
                    @"type": @"boolean",
                    @"description": @"dedupeEntries only: when true, return the full merge plan (groups, survivor, drop dates) without modifying the Archive. Default false.",
                },
            },
        },
    };
}

#pragma mark - Status block

/// Builds the always-returned status block. `actionResult` is merged in
/// when an action ran (carries action-specific fields like erasedCount).
+ (NSDictionary *)statusBlockMergingActionResult:(NSDictionary *)actionResult {
    ESVectorEngine *engine = [ESVectorEngine shared];
    NSArray<id<ESSummaryEmbedder>> *available = ESSummaryEmbedderActiveInstances();
    id<ESSummaryEmbedder> active = [ESVectorEngine summaryEmbedder];

    // One entry per registered summary embedder. The spec deliberately keeps
    // this small: identifier, language, dimension, max seq length, active flag.
    NSMutableArray *embedderInfo = [NSMutableArray arrayWithCapacity:available.count];
    for (id<ESSummaryEmbedder> e in available) {
        [embedderInfo addObject:@{
            @"identifier":   e.identifier ?: @"",
            @"language":     e.language ?: @"",
            @"dimension":    @(e.vectorDimension),
            @"maxSeqLength": @(e.maximumSequenceLength),
            @"active":       @([e.identifier isEqualToString:active.identifier]),
        }];
    }

    // Archive counts.
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSError *countErr = nil;

    NSFetchRequest *memReq = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    memReq.includesSubentities = NO;
    NSUInteger memoryCount = [ctx countForFetchRequest:memReq error:&countErr];
    if (countErr) memoryCount = 0;

    NSUInteger activeVectorCount = 0;
    NSUInteger missingActive = 0;
    if (active.identifier.length > 0) {
        NSFetchRequest *vecReq = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
        vecReq.predicate = [NSPredicate predicateWithFormat:@"embedderIdentifier == %@", active.identifier];
        countErr = nil;
        activeVectorCount = [ctx countForFetchRequest:vecReq error:&countErr];
        if (countErr) activeVectorCount = 0;

        NSFetchRequest *missingReq = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        missingReq.includesSubentities = NO;
        // Memories that (a) lack any active-embedder vector AND (b) have an
        // embeddable summary. The outer parentheses around the AND group are
        // load-bearing — without them NSPredicate's AND > OR precedence
        // makes any memory with a summary count as missing regardless of
        // vector status.
        missingReq.predicate = [NSPredicate predicateWithFormat:
            @"(SUBQUERY(vectors, $v, $v.embedderIdentifier == %@).@count == 0) AND "
            @"(summary != nil AND summary != %@)",
            active.identifier, @""];
        countErr = nil;
        missingActive = [ctx countForFetchRequest:missingReq error:&countErr];
        if (countErr) missingActive = 0;
    }

    NSDictionary *staleReport = [engine staleVectorReport];

    NSMutableDictionary *archive = [@{
        @"entryCount":                 @(memoryCount),
        @"activeVectorCount":           @(activeVectorCount),
        @"entriesWithoutActiveVector": @(missingActive),
        @"pendingVectorOperations":     @(engine.pendingVectorOperations),
        @"pendingEmbedder":             (engine.pendingEmbedderIdentifier ?: [NSNull null]),
        @"staleVectorCount":            staleReport[@"count"] ?: @0,
        @"staleEmbedderIDs":            staleReport[@"embedderIDs"] ?: @[],
    } mutableCopy];

    NSMutableDictionary *result = [@{
        @"activeEmbedder":     active.identifier ?: @"(none)",
        @"availableEmbedders": embedderInfo,
        @"archive":            archive,
    } mutableCopy];

    if (actionResult.count > 0) {
        [result addEntriesFromDictionary:actionResult];
    }
    return result;
}

#pragma mark - Execute

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {
    ESVectorEngine *engine = [ESVectorEngine shared];

    NSString *action = [ESMemoryToolBase stringFromArgs:arguments key:@"action"];

    // pruneTags and dedupeTags are pure tag-store ops — never gate them on vector operations.
    if (action.length > 0 && ![action isEqualToString:@"pruneTags"]
        && ![action isEqualToString:@"dedupeTags"] && engine.pendingVectorOperations > 0) {
        NSMutableDictionary *resp = [[self statusBlockMergingActionResult:nil] mutableCopy];
        resp[@"status"] = @"action_refused";
        resp[@"hint"] = @"Vector operations are in flight. Poll archive_maintenance() until pendingVectorOperations is 0, then retry.";
        return resp;
    }

    NSDictionary *actionResult = nil;

    if ([action isEqualToString:@"backfill"]) {
        [engine backfillMissingVectorsWithCompletion:^(NSUInteger n) {
            NSLog(@"[archive_maintenance] backfill complete: %lu memories", (unsigned long)n);
        }];
        actionResult = @{ @"status": @"backfill_started" };
    }
    else if ([action isEqualToString:@"reindexSummaries"]) {
        // Synchronous from the caller's POV — block until the engine
        // reports completion. Reindex of ~720 memories is ~20 minutes;
        // callers should expect a long-running response.
        __block BOOL done = NO;
        __block BOOL succ = NO;
        __block NSUInteger n = 0;
        __block NSError *err = nil;
        NSCondition *cond = [[NSCondition alloc] init];
        [engine recomputeAllVectorsWithCompletion:^(BOOL success, NSUInteger count, NSError * _Nullable e) {
            [cond lock];
            succ = success; n = count; err = e; done = YES;
            [cond signal];
            [cond unlock];
        }];
        [cond lock];
        while (!done) [cond wait];
        [cond unlock];
        actionResult = @{
            @"status":         succ ? @"reindex_complete" : @"reindex_failed",
            @"reindexedCount": @(n),
        };
    }
    else if ([action isEqualToString:@"erase"]) {
        NSUInteger erased = [engine eraseVectorsForActiveEmbedder];
        actionResult = @{
            @"status":      @"erase_complete",
            @"erasedCount": @(erased),
        };
    }
    else if ([action isEqualToString:@"clean"]) {
        NSDictionary *report = [engine cleanArchive];
        NSMutableDictionary *m = [report mutableCopy];
        m[@"status"] = @"clean_complete";
        actionResult = m;
    }
    else if ([action isEqualToString:@"pruneTags"]) {
        actionResult = [self pruneExpiredTagsWithArguments:arguments];
    }
    else if ([action isEqualToString:@"dedupeTags"]) {
        actionResult = [self dedupeTags];
    }
    else if ([action isEqualToString:@"dedupeEntries"]) {
        BOOL dryRun = [ESMemoryToolBase boolFromArgs:arguments key:@"dryRun" default:NO];
        actionResult = [self dedupeEntriesDryRun:dryRun];
    }
    else if ([action isEqualToString:@"dedupeEmbedders"]) {
        actionResult = [self dedupeEmbedders];
    }

    // --- 3. response ---
    NSMutableDictionary *resp = [[self statusBlockMergingActionResult:actionResult] mutableCopy];
    if (!resp[@"status"]) resp[@"status"] = @"current";
    return resp;
}

#pragma mark - Tag prune

/// Hard-delete ephemeral tags whose dateExpired passed more than graceDays ago.
/// Expiry already hides them from every query (lfind, archive_tags list); this
/// reclaims the dead rows so they stop syncing and accumulating. CDTag→memories
/// is Nullify, so deletion just detaches cleanly.
+ (NSDictionary *)pruneExpiredTagsWithArguments:(NSDictionary *)arguments {
    NSInteger graceDays = [ESMemoryToolBase integerFromArgs:arguments key:@"graceDays" default:7];
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    // One implementation, shared with the launch sweep (see ESTagJanitor).
    NSArray<NSString *> *names = [ESTagJanitor pruneExpiredTagsWithGraceDays:graceDays
                                                                     context:ctx];
    [[ESCoreDataStack shared] saveContext];

    return @{
        @"status":      @"prune_complete",
        @"prunedCount": @(names.count),
        @"prunedTags":  names,
        @"graceDays":   @(graceDays < 0 ? 0 : graceDays),
    };
}

#pragma mark - Tag dedupe

/// Reconcile same-name tag duplicates. Name-uniqueness is enforced only at
/// creation (CDTag findByName) and CloudKit cannot enforce it across devices, so
/// offline/multi-device creation can leave two CDTags with the same name. This
/// groups tags by case- and diacritic-folded name (matching findByName's ==[cd]);
/// for each collision it keeps one canonical tag, moves every other tag's
/// memberships onto it, and deletes the rest. Canonical = most memberships, then
/// permanent over expiring, then oldest. If any tag in the group was permanent,
/// the survivor is made permanent — a curated tag must not vanish via expiry.
+ (NSDictionary *)dedupeTags {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSError *ferr = nil;
    NSArray<CDTag *> *all = [ctx executeFetchRequest:[CDTag fetchRequest] error:&ferr];
    if (ferr || !all) {
        return @{ @"status": @"dedupe_failed", @"hint": ferr.localizedDescription ?: @"fetch failed" };
    }

    NSMutableDictionary<NSString *, NSMutableArray<CDTag *> *> *groups = [NSMutableDictionary dictionary];
    for (CDTag *t in all) {
        if (t.name.length == 0) continue;
        NSString *key = [[t.name stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                     locale:nil] lowercaseString];
        NSMutableArray *g = groups[key];
        if (!g) { g = [NSMutableArray array]; groups[key] = g; }
        [g addObject:t];
    }

    NSUInteger groupsMerged = 0, tagsDeleted = 0, membershipsMoved = 0;
    NSMutableArray<NSDictionary *> *merged = [NSMutableArray array];

    for (NSString *key in groups) {
        NSArray<CDTag *> *g = groups[key];
        if (g.count < 2) continue;

        CDTag *canonical = [[g sortedArrayUsingComparator:^NSComparisonResult(CDTag *a, CDTag *b) {
            if (a.memories.count != b.memories.count)
                return a.memories.count > b.memories.count ? NSOrderedAscending : NSOrderedDescending;
            BOOL pa = (a.dateExpired == nil), pb = (b.dateExpired == nil);
            if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;
            NSDate *da = a.dateCreated ?: NSDate.distantFuture, *db = b.dateCreated ?: NSDate.distantFuture;
            return [da compare:db];
        }] firstObject];

        BOOL anyPermanent = NO;
        for (CDTag *t in g) { if (t.dateExpired == nil) { anyPermanent = YES; break; } }

        for (CDTag *dup in g) {
            if (dup == canonical) continue;
            for (CDMemory *m in dup.memories.allObjects) {
                [m removeTagsObject:dup];
                [m addTagsObject:canonical];
                membershipsMoved++;
            }
            [ctx deleteObject:dup];
            tagsDeleted++;
        }
        if (anyPermanent) canonical.dateExpired = nil;
        groupsMerged++;
        [merged addObject:@{ @"name": canonical.name ?: @"", @"foldedIn": @(g.count - 1) }];
    }

    if (tagsDeleted > 0) [[ESCoreDataStack shared] saveContext];

    return @{
        @"status":           @"dedupe_complete",
        @"groupsMerged":     @(groupsMerged),
        @"tagsDeleted":      @(tagsDeleted),
        @"membershipsMoved": @(membershipsMoved),
        @"merged":           merged,
    };
}

#pragma mark - Memory dedupe

/// Reconcile byte-identical duplicate memories — same title, same body, same
/// author. These accumulate from historical double-writes (two rows in the
/// same second) and backdated re-imports (a backfill with dateCreated
/// overrides re-storing what a live session had already stored). For each
/// exact-match group the OLDEST copy survives — the original dateCreated is
/// the archive's history, consistent with the update-don't-restore doctrine —
/// and every duplicate's graph weight (tags, links, comments, references,
/// revision history, access stats) folds onto it before the duplicate is
/// deleted. Groups containing a locked memory are skipped entirely, matching
/// `clean`'s locked handling. Same-title memories whose bodies differ are
/// never touched — those are revisions, and merging them is curation, not
/// maintenance.
+ (NSDictionary *)dedupeEntriesDryRun:(BOOL)dryRun {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSError *ferr = nil;
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    req.includesSubentities = NO;
    NSArray<CDMemory *> *all = [ctx executeFetchRequest:req error:&ferr];
    if (ferr || !all) {
        return @{ @"status": @"dedupe_failed", @"hint": ferr.localizedDescription ?: @"fetch failed" };
    }

    // Exact-match grouping on (title, body, author), joined with a separator
    // that cannot occur in text. Empty-body rows are `clean`'s territory.
    NSMutableDictionary<NSString *, NSMutableArray<CDMemory *> *> *groups = [NSMutableDictionary dictionary];
    for (CDMemory *m in all) {
        if (m.body.length == 0) continue;
        NSString *key = [NSString stringWithFormat:@"%@\x01%@\x01%@",
                         m.title ?: @"", m.body, m.author ?: @""];
        NSMutableArray *g = groups[key];
        if (!g) { g = [NSMutableArray array]; groups[key] = g; }
        [g addObject:m];
    }

    NSUInteger groupsMerged = 0, deleted = 0, tagsMoved = 0, linksMoved = 0,
               commentsMoved = 0, referencesMoved = 0, revisionsMoved = 0,
               lockedGroupsMerged = 0;
    NSMutableArray<NSDictionary *> *plan = [NSMutableArray array];
    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];

    for (NSString *key in groups) {
        NSArray<CDMemory *> *g = groups[key];
        if (g.count < 2) continue;

        NSArray<CDMemory *> *sorted = [g sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
            NSDate *da = a.dateCreated ?: NSDate.distantFuture;
            NSDate *db = b.dateCreated ?: NSDate.distantFuture;
            NSComparisonResult r = [da compare:db];
            if (r != NSOrderedSame) return r;
            NSDate *ma = a.dateModified ?: NSDate.distantFuture;
            NSDate *mb = b.dateModified ?: NSDate.distantFuture;
            return [ma compare:mb];
        }];
        CDMemory *survivor = sorted.firstObject;

        NSMutableArray<NSString *> *dropDates = [NSMutableArray array];
        for (CDMemory *dup in sorted) {
            if (dup == survivor) continue;
            [dropDates addObject:dup.dateCreated ? [df stringFromDate:dup.dateCreated] : @"(no date)"];
        }

        if (dryRun) {
            deleted += sorted.count - 1;
            for (CDMemory *m in sorted) { if (m.locked) { lockedGroupsMerged++; break; } }
        } else {
            // Shared merge core (ESDedupeMergeCore) — same implementation the
            // automatic deduplicator uses on CloudKit import.
            NSDictionary<NSString *, NSNumber *> *c = ESDedupeMergeSortedGroup(sorted, ctx);
            deleted            += c[@"deleted"].unsignedIntegerValue;
            tagsMoved          += c[@"tagsMoved"].unsignedIntegerValue;
            linksMoved         += c[@"linksMoved"].unsignedIntegerValue;
            commentsMoved      += c[@"commentsMoved"].unsignedIntegerValue;
            referencesMoved    += c[@"referencesMoved"].unsignedIntegerValue;
            revisionsMoved     += c[@"revisionsMoved"].unsignedIntegerValue;
            lockedGroupsMerged += c[@"lockedGroup"].unsignedIntegerValue;
        }

        groupsMerged++;
        [plan addObject:@{
            @"title":  survivor.title ?: @"",
            @"copies": @(g.count),
            @"keep":   survivor.dateCreated ? [df stringFromDate:survivor.dateCreated] : @"(no date)",
            @"drop":   dropDates,
        }];
    }

    if (!dryRun && deleted > 0) [[ESCoreDataStack shared] saveContext];

    NSString *deletedKey = dryRun ? @"entriesToDelete" : @"entriesDeleted";
    NSMutableDictionary *out = [@{
        @"status":              dryRun ? @"dedupe_dry_run" : @"dedupe_complete",
        @"duplicateGroups":     @(groupsMerged),
        deletedKey:             @(deleted),
        @"lockedGroupsMerged":  @(lockedGroupsMerged),
        @"plan":                plan,
    } mutableCopy];
    if (!dryRun) {
        out[@"tagsMoved"]       = @(tagsMoved);
        out[@"linksMoved"]      = @(linksMoved);
        out[@"commentsMoved"]   = @(commentsMoved);
        out[@"referencesMoved"] = @(referencesMoved);
        out[@"revisionsMoved"]  = @(revisionsMoved);
    }
    return out;
}

#pragma mark - Embedder dedupe

/// Reconcile duplicate CDEmbedder inventory rows. findOrCreateWithIdentifier
/// enforces identifier-uniqueness only locally, so CloudKit sync across
/// devices can leave several rows for one model — vectors then scatter across
/// them. Retrieval is unaffected (the cache predicate matches the identifier
/// string, not the row), but the inventory drifts, and CDEmbedder→vectors is
/// Cascade so a naive row cleanup would take the vectors with it. The row
/// with the most vectors (then the oldest) survives; every other row's
/// vectors are re-pointed onto it before the emptied rows are deleted.
+ (NSDictionary *)dedupeEmbedders {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSError *ferr = nil;
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDEmbedder"];
    NSArray<CDEmbedder *> *all = [ctx executeFetchRequest:req error:&ferr];
    if (ferr || !all) {
        return @{ @"status": @"dedupe_failed", @"hint": ferr.localizedDescription ?: @"fetch failed" };
    }

    NSMutableDictionary<NSString *, NSMutableArray<CDEmbedder *> *> *groups = [NSMutableDictionary dictionary];
    for (CDEmbedder *e in all) {
        if (e.identifier.length == 0) continue;
        NSMutableArray *g = groups[e.identifier];
        if (!g) { g = [NSMutableArray array]; groups[e.identifier] = g; }
        [g addObject:e];
    }

    NSUInteger groupsMerged = 0, rowsDeleted = 0, vectorsMoved = 0;
    NSMutableArray<NSDictionary *> *merged = [NSMutableArray array];

    for (NSString *identifier in groups) {
        NSArray<CDEmbedder *> *g = groups[identifier];
        if (g.count < 2) continue;

        CDEmbedder *canonical = [[g sortedArrayUsingComparator:^NSComparisonResult(CDEmbedder *a, CDEmbedder *b) {
            if (a.vectors.count != b.vectors.count)
                return a.vectors.count > b.vectors.count ? NSOrderedAscending : NSOrderedDescending;
            NSDate *da = a.dateCreated ?: NSDate.distantFuture, *db = b.dateCreated ?: NSDate.distantFuture;
            return [da compare:db];
        }] firstObject];

        NSUInteger movedHere = 0;
        for (CDEmbedder *dup in g) {
            if (dup == canonical) continue;
            for (CDVector *v in dup.vectors.allObjects) {
                v.embedder = canonical;
                movedHere++;
            }
            [ctx deleteObject:dup];
            rowsDeleted++;
        }
        vectorsMoved += movedHere;
        groupsMerged++;
        [merged addObject:@{ @"identifier": identifier,
                             @"foldedIn":   @(g.count - 1),
                             @"vectorsMoved": @(movedHere) }];
    }

    if (rowsDeleted > 0) [[ESCoreDataStack shared] saveContext];

    return @{
        @"status":       @"dedupe_complete",
        @"groupsMerged": @(groupsMerged),
        @"rowsDeleted":  @(rowsDeleted),
        @"vectorsMoved": @(vectorsMoved),
        @"merged":       merged,
    };
}

@end
