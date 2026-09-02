//
//  ESUUIDStampedObject.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Common parent for every entity class that carries a `uuid` attribute
//  (CDMemory, CDLink, CDMarginalia, CDReference, CDTag, CDEmbedder — and
//  CDMemoryRevision via CDMemory). The uuid is the stable identity the
//  deduplicator recognizes CloudKit replay twins by, and the synced
//  tiebreak that makes survivor election deterministic across devices
//  (the objectID URI, the previous tiebreak, is per-device only).
//
//  Two guarantees, one class:
//
//  1. awakeFromInsert stamps a fresh uuid on every locally created row —
//     every factory, initWithCoder: restore, and ad-hoc insert, with no
//     caller cooperation. The nil-guard keeps a CloudKit import that
//     materializes through a regular insert from being re-stamped over
//     the record's real uuid. Model-driven: an entity without a `uuid`
//     attribute passes through untouched, so parenting a future entity
//     here is always safe.
//
//  2. +backfillUUIDsInContext: is the one-shot launch pass for rows that
//     predate the attribute (and legacy rows syncing in from old-schema
//     devices). It iterates the model, finds every root entity declaring
//     `uuid`, and stamps the nil rows. Idempotent — a clean archive costs
//     one indexed fetch per entity. Deliberately NOT done lazily in
//     awakeFromFetch: change processing is disabled there, so a stamp
//     would never persist, and each device would mint a different
//     ephemeral uuid per fetch — the exact opposite of a stable tiebreak.
//
//  Cross-device note: two devices that both backfill the same legacy
//  synced row assign different uuids; CloudKit's per-field last-writer-
//  wins converges them after a sync round-trip. Transient divergence,
//  then stable — strictly better than the URI, which never converges.
//

#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESUUIDStampedObject : NSManagedObject

/// Stamp a fresh uuid on every row (of every uuid-carrying root entity)
/// whose uuid is nil. Does not save — the caller commits. Returns the
/// number of rows stamped.
+ (NSUInteger)backfillUUIDsInContext:(NSManagedObjectContext *)ctx;

@end

NS_ASSUME_NONNULL_END
