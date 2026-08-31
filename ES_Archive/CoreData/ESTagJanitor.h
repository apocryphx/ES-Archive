//
//  ESTagJanitor.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
@class NSManagedObjectContext, NSManagedObjectID;

NS_ASSUME_NONNULL_BEGIN

/// Tag housekeeping: nothing in the archive deletes a CDTag when it loses its
/// last memory, so orphans accumulate. Every path that detaches a tag —
/// archive_update, archive_untag, tag merges, restore-over-an-existing-memory,
/// deleting a persona — leaves the CDTag row behind.
///
/// Deliberately NOT a live trigger. "Last memory removed" is a normal transient
/// state: both -[ESMemoryUpdateTool] and -[CDMemory initWithCoder:] replace a
/// memory's tags by removing all of them and re-adding from the incoming set, so
/// a tag that survives an ordinary edit passes through zero members on the way.
/// A trigger firing there would delete the tag and let connect-or-create mint a
/// replacement, silently losing its kind, dateCreated and dateExpired. These
/// sweeps therefore run only at rest — at launch, or after a persona delete.
@interface ESTagJanitor : NSObject

#pragma mark - Persona deletion (causation known — no heuristic)

/// The tags attached to `author`'s memories. Capture BEFORE deleting the
/// persona, then hand the result to +deleteOrphanedAmong:context: afterwards.
/// Because we know these tags had members and we removed them, a tag left at
/// zero was orphaned by this operation — no guessing required, and a tag that
/// was already empty beforehand is never in the set.
+ (NSSet<NSManagedObjectID *> *)tagIDsForAuthor:(NSString *)author
                                        context:(NSManagedObjectContext *)context;

/// Delete whichever of `tagIDs` now have no memories. Returns the names deleted.
/// Does not save — the caller saves, so the sweep joins the delete's transaction.
+ (NSArray<NSString *> *)deleteOrphanedAmong:(NSSet<NSManagedObjectID *> *)tagIDs
                                     context:(NSManagedObjectContext *)context;

#pragma mark - Startup sweep (causation unknown — conservative)

/// Prune expired, then sweep long-standing orphans. Logs what it removed.
/// Safe to call on every launch; a clean archive is a no-op.
+ (void)runStartupSweepWithContext:(NSManagedObjectContext *)context;

/// Hard-delete tags whose dateExpired passed more than `graceDays` ago. Expiry
/// already hides them from every query; this reclaims the rows so they stop
/// syncing. Shared with archive_maintenance's `pruneTags` action.
+ (NSArray<NSString *> *)pruneExpiredTagsWithGraceDays:(NSInteger)graceDays
                                               context:(NSManagedObjectContext *)context;

/// Delete every tag with no memories. A tag exists to group memories; an empty
/// one has no function, and re-creating one costs nothing.
///
/// Deliberately unqualified by kind or by age. Kind records that someone chose
/// to create the tag, not that they still want it. Age is actively wrong: a
/// restore mints its tags through connect-or-create with TODAY's dateCreated, so
/// a grace period would shield exactly the tags an archive dragged in and left
/// behind — the commonest source of orphans there is.
///
/// The one exemption is dateExpired: ephemeral tags have their own lifecycle and
/// are handled by the prune above, which is what lets a staging bucket sit empty
/// mid-curation without being swept.
+ (NSArray<NSString *> *)sweepOrphanedTagsInContext:(NSManagedObjectContext *)context;

@end

NS_ASSUME_NONNULL_END
