//
//  ESDedupeMergeCore.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  The one place duplicate CDMemory rows are merged. Two callers:
//  archive_maintenance's dedupeMemories action (content-grouped, on demand)
//  and ESDeduplicator (uuid-grouped, automatic on CloudKit import).
//
//  The caller owns two decisions this function deliberately does not make:
//  which rows form a group, and which row survives (survivor = first element
//  of the sorted array). This function only executes the merge: tags, links,
//  marginalia, references, revisions, and vectors move to the survivor;
//  reading stats fold; privacy and locked take the stricter value; the
//  remaining rows are deleted. No save — the caller commits.
//

#import <CoreData/CoreData.h>

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

/// Merge `sorted[1...]` into `sorted[0]` and delete them. Returns counters:
/// deleted, tagsMoved, linksMoved, commentsMoved, referencesMoved,
/// revisionsMoved, lockedGroup (1 when any row in the group carried the
/// locked flag — the survivor inherits it).
NSDictionary<NSString *, NSNumber *> *ESDedupeMergeSortedGroup(NSArray<CDMemory *> *sorted,
                                                               NSManagedObjectContext *ctx);

NS_ASSUME_NONNULL_END
