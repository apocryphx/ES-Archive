//
//  ESTagJanitor.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTagJanitor.h"
#import "ESLog.h"
#import "CDTag.h"
#import <CoreData/CoreData.h>

/// Grace period before an expired tag's row is reclaimed. Matches the default
/// of archive_maintenance's pruneTags, so the automatic and manual paths agree.
static const NSInteger kDefaultGraceDays = 7;

@implementation ESTagJanitor

#pragma mark - Persona deletion

+ (NSSet<NSManagedObjectID *> *)tagIDsForAuthor:(NSString *)author
                                        context:(NSManagedObjectContext *)context {
    if (author.length == 0) return [NSSet set];

    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDTag"];
    req.predicate = [NSPredicate predicateWithFormat:@"ANY memories.author == %@", author];

    NSError *err = nil;
    NSArray<CDTag *> *tags = [context executeFetchRequest:req error:&err];
    if (err || !tags) {
        ESLog(@"ESTagJanitor: could not fetch tags for persona “%@”: %@", author, err);
        return [NSSet set];
    }

    NSMutableSet<NSManagedObjectID *> *ids = [NSMutableSet setWithCapacity:tags.count];
    for (CDTag *tag in tags) [ids addObject:tag.objectID];
    return ids;
}

+ (NSArray<NSString *> *)deleteOrphanedAmong:(NSSet<NSManagedObjectID *> *)tagIDs
                                     context:(NSManagedObjectContext *)context {
    NSMutableArray<NSString *> *deleted = [NSMutableArray array];

    for (NSManagedObjectID *objectID in tagIDs) {
        CDTag *tag = [context objectRegisteredForID:objectID];
        if (!tag) {
            NSError *err = nil;
            tag = (CDTag *)[context existingObjectWithID:objectID error:&err];
            if (!tag) continue;   // already gone
        }
        if (tag.isDeleted) continue;
        if (tag.memories.count > 0) continue;   // still carried by someone else

        if (tag.name.length) [deleted addObject:tag.name];
        [context deleteObject:tag];
    }
    return deleted;
}

#pragma mark - Startup sweep

+ (void)runStartupSweepWithContext:(NSManagedObjectContext *)context {
    NSArray<NSString *> *pruned = [self pruneExpiredTagsWithGraceDays:kDefaultGraceDays
                                                             context:context];
    NSArray<NSString *> *swept = [self sweepOrphanedTagsInContext:context];

    if (pruned.count == 0 && swept.count == 0) return;   // clean archive — no-op

    if (pruned.count > 0) {
        ESLog(@"ESTagJanitor: pruned %lu expired tag(s): %@",
              (unsigned long)pruned.count, [pruned componentsJoinedByString:@", "]);
    }
    if (swept.count > 0) {
        ESLog(@"ESTagJanitor: swept %lu orphaned tag(s): %@",
              (unsigned long)swept.count, [swept componentsJoinedByString:@", "]);
    }

    NSError *saveErr = nil;
    if (context.hasChanges && ![context save:&saveErr]) {
        ESLog(@"ESTagJanitor: sweep failed to save: %@", saveErr);
    }
}

+ (NSArray<NSString *> *)pruneExpiredTagsWithGraceDays:(NSInteger)graceDays
                                               context:(NSManagedObjectContext *)context {
    if (graceDays < 0) graceDays = 0;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(graceDays * 86400.0)];

    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDTag"];
    req.predicate = [NSPredicate predicateWithFormat:
                     @"dateExpired != nil AND dateExpired < %@", cutoff];

    NSError *err = nil;
    NSArray<CDTag *> *expired = [context executeFetchRequest:req error:&err];
    if (err || !expired) {
        ESLog(@"ESTagJanitor: expired-tag fetch failed: %@", err);
        return @[];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:expired.count];
    for (CDTag *tag in expired) {
        if (tag.name.length) [names addObject:tag.name];
        [context deleteObject:tag];
    }
    return names;
}

+ (NSArray<NSString *> *)sweepOrphanedTagsInContext:(NSManagedObjectContext *)context {
    // Emptiness is the whole test. Neither of the two things that look like
    // useful qualifiers actually is:
    //
    //   * kind says someone chose to create the tag, not that they still want
    //     it — filtering on it exempts every person/project/principle tag from
    //     cleanup forever, trading one pile of debris for another.
    //   * age is worse than useless here, because a restore mints its tags
    //     through connect-or-create and stamps them with TODAY. Tags brought in
    //     by an archive and orphaned soon after are the most common case there
    //     is, and a grace period on dateCreated protects precisely those.
    //
    // What remains is dateExpired: an ephemeral tag has its own lifecycle and
    // belongs to the prune pass, which is what keeps a staging bucket alive
    // while it is briefly empty mid-curation.
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDTag"];
    req.predicate = [NSPredicate predicateWithFormat:
                     @"memories.@count == 0 AND dateExpired == nil"];

    NSError *err = nil;
    NSArray<CDTag *> *orphans = [context executeFetchRequest:req error:&err];
    if (err || !orphans) {
        ESLog(@"ESTagJanitor: orphan-tag fetch failed: %@", err);
        return @[];
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:orphans.count];
    for (CDTag *tag in orphans) {
        if (tag.name.length) [names addObject:tag.name];
        [context deleteObject:tag];
    }
    return names;
}

@end
