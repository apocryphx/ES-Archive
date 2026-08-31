//
//  ESDeduplicator.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Automatic collapse of CloudKit duplicate rows across EVERY entity class
//  (v1.7.1, extended to all classes on the UDS branch).
//
//  Core Data + CloudKit can materialize the same logical record as two rows
//  (import replay, cross-device races). This happens to every syncable
//  entity, not just memories: a resurrected memory carries its own twins,
//  but tags, links, comments, references and revision snapshots each replay
//  on their own too. Every such row is stamped with a stable identity at
//  creation, so twins are recognizable and safe to merge mechanically:
//
//    - CDMemory, CDLink, CDMarginalia, CDReference, CDMemoryRevision each
//      carry a `uuid` set once at creation — twins share it. Same-uuid rows
//      are structurally identical; the survivor rule picks one and the rest
//      are deleted (memories fold their children onto the survivor first via
//      ESDedupeMergeCore; the leaf entities have nothing to move).
//    - CDTag has no uuid — its identity is its (case/diacritic-folded) name,
//      the same key findOrCreateByName enforces locally. Twins union their
//      memberships onto the survivor.
//    - CDVector / CDEmbedder are pure derived data (recreatable from the
//      memory's summary), so they aren't preserved — the vector invariant is
//      simply re-asserted: one active-embedder vector per embeddable memory,
//      everything else purged.
//
//  Same-title/different-uuid near-duplicate MEMORIES are deliberately NOT
//  touched: distinct uuids mean distinct authored records, and that judgment
//  stays with a mind (see the July 5 2026 Essay Seven incident).
//
//  Flow:
//
//    1. DETECTOR — an NSFetchedResultsController on a background context
//       (imports merge in via automaticallyMergesChangesFromParent) watches
//       CDMemory inserts and emits uuid strings. Low-latency path for the
//       highest-volume, highest-value entity. Chosen over
//       NSPersistentStoreRemoteChange deliberately: the FRC delivers
//       materialized inserts batched per merge, where the remote-change
//       notification is a fire-hose of empty pings that would need token
//       bookkeeping, history replay, and author filtering to say less.
//
//    2. ACCUMULATOR — a pending NSMutableSet behind a serial queue with a
//       debounced drain. Set semantics coalesce repeated hints; the drain
//       hands the main thread occasional chunky batches instead of a stream.
//
//    3. ACTOR — a block on the main queue (the engine's single writer). It
//       re-derives everything from live data: does the group still exist,
//       which row survives, what moves. Memory merges go through the same
//       ESDedupeMergeCore as archive_maintenance's dedupeEntries action.
//
//    4. SWEEP — a full re-derivation across all entity classes. Runs at
//       launch (covers duplicates that arrived while the app was dead) and,
//       debounced, on every store remote change (covers the leaf entities the
//       memory FRC doesn't watch, and backstops the memory path). Cheap when
//       clean: a handful of frequency-count fetches and no write.
//
//  Survivor rule: oldest dateCreated, then oldest dateModified (memories),
//  then the permanent objectID URI as a stable local tiebreak. Local
//  determinism is sufficient because the exclusive-listener model
//  (listener-as-mutex, May 23 2026) means one engine runs against the store
//  at a time; see the scope note at -sortedBySurvivorRule: for why the
//  CloudKit recordName is deliberately not used.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESDeduplicator : NSObject

+ (instancetype)shared;

/// Install the background detector and the remote-change sweep trigger, then
/// run one launch sweep. Call once, after the persistent store has loaded.
/// Safe to call again (no-op).
- (void)start;

/// One-shot sweep of the whole archive across every entity class, feeding the
/// same main-thread actor. Called from start (covers duplicates that arrived
/// while the app was dead) and, debounced, on store remote changes; harmless
/// to call anytime.
- (void)sweep;

@end

NS_ASSUME_NONNULL_END
