//
//  ESDeduplicator.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESDeduplicator.h"
#import "ESDedupeMergeCore.h"
#import "ESUUIDStampedObject.h"
#import "ESCoreDataStack.h"
#import "ESMemoryMaintenanceTool.h"
#import "ESVectorEngine.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "CDVector.h"
#import "ESLog.h"
#import <CoreData/CoreData.h>

// Debounce window for the accumulator's drain. Long enough to coalesce a
// sync burst into one batch, short enough that a lone duplicate collapses
// promptly.
static const int64_t kDrainDelayNsec = (int64_t)(0.75 * NSEC_PER_SEC);

// Debounce window for the remote-change → full-sweep trigger. Wider than the
// memory drain: a full sweep is the coarse backstop for the leaf entities, so
// it coalesces a whole CloudKit merge burst into a single pass.
static const int64_t kSweepDebounceNsec = (int64_t)(2.0 * NSEC_PER_SEC);

// Leaf entities whose only duplication mode is CloudKit replay: same uuid,
// byte-identical bodies, nothing hanging off them that a memory merge hasn't
// already re-homed. Collapsed by uuid, keeping the survivor and deleting the
// twins. (CDMemory is handled separately — it folds children onto the
// survivor. CDMemoryRevision is a CDMemory subentity but carries its own
// uuid, so it dedupes as a leaf.)
static NSArray<NSString *> *ESUUIDLeafEntities(void) {
    return @[ @"CDLink", @"CDMarginalia", @"CDReference", @"CDMemoryRevision" ];
}

@interface ESDeduplicator () <NSFetchedResultsControllerDelegate>
@end

@implementation ESDeduplicator {
    BOOL _started;
    NSManagedObjectContext *_detectorContext;              // background; reader only
    NSFetchedResultsController<CDMemory *> *_detector;
    dispatch_queue_t _hintQueue;                            // serial accumulator
    NSMutableSet<NSString *> *_pending;                     // guarded by _hintQueue
    BOOL _drainScheduled;                                   // guarded by _hintQueue
    BOOL _sweepScheduled;                                   // guarded by _hintQueue
}

+ (instancetype)shared {
    static ESDeduplicator *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[ESDeduplicator alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _hintQueue = dispatch_queue_create("com.elarity.es-archive.deduplicator",
                                       dispatch_queue_attr_make_with_qos_class(
                                           DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    _pending = [NSMutableSet set];
    return self;
}

#pragma mark - Stage 1: detector (background FRC, observes only)

- (void)start {
    if (_started) return;
    _started = YES;

    NSPersistentCloudKitContainer *container = [ESCoreDataStack shared].persistentContainer;
    _detectorContext = [container newBackgroundContext];
    // CloudKit imports land via the mirroring delegate's own context; this
    // merge flag is what routes them into the detector's view of the world.
    _detectorContext.automaticallyMergesChangesFromParent = YES;

    [_detectorContext performBlock:^{
        NSFetchRequest<CDMemory *> *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        req.includesSubentities = NO;
        req.fetchBatchSize = 100;   // change feed, not a data source — keep it faulted
        req.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES] ];

        self->_detector = [[NSFetchedResultsController alloc]
            initWithFetchRequest:req
            managedObjectContext:self->_detectorContext
              sectionNameKeyPath:nil
                       cacheName:nil];
        self->_detector.delegate = self;

        NSError *err = nil;
        if (![self->_detector performFetch:&err]) {
            ESLogAlways(@"Deduplicator: detector fetch failed: %@", err.localizedDescription);
            return;
        }
        ESLog(@"Deduplicator: detector watching %lu memories",
              (unsigned long)self->_detector.fetchedObjects.count);
    }];

    // Warm path: anything that syncs in while we're running. The memory FRC
    // above covers memory inserts with low latency; this coarse trigger is the
    // backstop that reaches the leaf entities (tags, links, comments,
    // references, revisions) the FRC doesn't watch. Debounced in the handler.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeRemoteChange:)
                                                 name:NSPersistentStoreRemoteChangeNotification
                                               object:nil];

    // One-shot uuid backfill for rows that predate the attribute (and
    // legacy rows syncing in from old-schema devices), so the survivor
    // tiebreak is available before the first sweep. Both blocks run on the
    // main queue, so ordering ahead of the sweep below is guaranteed.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
        if ([ESUUIDStampedObject backfillUUIDsInContext:ctx] > 0) {
            [[ESCoreDataStack shared] saveContext];
        }
    });

    // Cold path: whatever synced in while the app was dead.
    [self sweep];
}

// Delegate callbacks arrive on the detector context's queue. Inserts only —
// updates and deletes (including our own merges echoing back) are noise here.
- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {
    if (type != NSFetchedResultsChangeInsert) return;
    NSString *uuidString = [(CDMemory *)anObject uuid].UUIDString;
    if (uuidString.length == 0) return;
    [self flagCandidate:uuidString];
}

#pragma mark - Stage 2: accumulator (serial queue, coalesces, debounced drain)

- (void)flagCandidate:(NSString *)uuidString {
    dispatch_async(_hintQueue, ^{
        [self->_pending addObject:uuidString];
        if (self->_drainScheduled) return;
        self->_drainScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kDrainDelayNsec), self->_hintQueue, ^{
            self->_drainScheduled = NO;
            if (self->_pending.count == 0) return;
            NSSet<NSString *> *batch = [self->_pending copy];
            [self->_pending removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self collapseCandidates:batch];
            });
        });
    });
}

// Remote change → debounced full sweep. The notification is a bare "something
// synced" ping; we don't parse it (no history replay, no token bookkeeping —
// the critique that ruled it out as the memory DETECTOR doesn't apply to a
// coarse re-derivation trigger). Coalesced so a merge burst is one sweep.
- (void)storeRemoteChange:(NSNotification *)note {
    dispatch_async(_hintQueue, ^{
        if (self->_sweepScheduled) return;
        self->_sweepScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSweepDebounceNsec), self->_hintQueue, ^{
            self->_sweepScheduled = NO;
            [self sweep];   // sweep hops to the main queue itself
        });
    });
}

#pragma mark - Stage 3: actor (main queue — the engine's single writer)

// Hints are advisory. Everything is re-derived from live data here: whether
// the group still exists, which row survives, what moves. Stale or duplicate
// hints reduce to a cheap indexed fetch and a no-op.
- (void)collapseCandidates:(NSSet<NSString *> *)uuidStrings {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    NSUInteger groups = 0, deleted = 0;
    for (NSString *s in uuidStrings) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:s];
        if (!uuid) continue;

        NSFetchRequest<CDMemory *> *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        req.includesSubentities = NO;
        req.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
        NSError *err = nil;
        NSArray<CDMemory *> *rows = [ctx executeFetchRequest:req error:&err];
        if (err || rows.count < 2) continue;

        NSDictionary *counts = ESDedupeMergeSortedGroup([self sortedBySurvivorRule:rows], ctx);
        groups  += 1;
        deleted += [counts[@"deleted"] unsignedIntegerValue];
    }

    if (groups > 0) {
        [[ESCoreDataStack shared] saveContext];
        ESLogAlways(@"Deduplicator: collapsed %lu duplicate group%s (%lu row%s removed)",
                    (unsigned long)groups, groups == 1 ? "" : "s",
                    (unsigned long)deleted, deleted == 1 ? "" : "s");
    }
}

// Survivor = first: oldest dateCreated, then oldest dateModified, then the
// permanent objectID URI as a stable local tiebreak (true twins carry
// identical dates, so the tiebreak does real work).
//
// Scope note: the URI tiebreak is deterministic per device, not across
// devices. Cross-device determinism only matters if two Macs run the engine
// concurrently against one CloudKit account — which the exclusive-listener
// model already rules out (listener-as-mutex, May 23 2026). Revisit if
// multi-device servers ever become a supported topology. The obvious synced
// tiebreak — the CloudKit recordName via recordIDForManagedObjectID: — is
// NOT usable here: that API synchronously waits on the persistence executor
// and deadlocks the main thread when called during startup (observed
// hanging v1.7.1's first launch; sampled at _PFRequestExecutor wait).
- (NSArray<CDMemory *> *)sortedBySurvivorRule:(NSArray<CDMemory *> *)rows {
    return [rows sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        NSDate *da = a.dateCreated ?: NSDate.distantFuture;
        NSDate *db = b.dateCreated ?: NSDate.distantFuture;
        NSComparisonResult r = [da compare:db];
        if (r != NSOrderedSame) return r;

        NSDate *ma = a.dateModified ?: NSDate.distantFuture;
        NSDate *mb = b.dateModified ?: NSDate.distantFuture;
        r = [ma compare:mb];
        if (r != NSOrderedSame) return r;

        // Permanent object URIs (rows fetched from the store are never
        // temporary IDs). Pure string compare — no store round-trip.
        NSString *ua = a.objectID.URIRepresentation.absoluteString;
        NSString *ub = b.objectID.URIRepresentation.absoluteString;
        return [ua compare:ub];
    }];
}

// The survivor rule for leaf entities and tags: oldest dateCreated, then the
// permanent objectID URI. (No dateModified on these entities.)
- (NSArray<NSManagedObject *> *)sortedByCreationRule:(NSArray<NSManagedObject *> *)rows {
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSManagedObject *a, NSManagedObject *b) {
        NSDate *da = [a valueForKey:@"dateCreated"] ?: NSDate.distantFuture;
        NSDate *db = [b valueForKey:@"dateCreated"] ?: NSDate.distantFuture;
        NSComparisonResult r = [da compare:db];
        if (r != NSOrderedSame) return r;
        NSString *ua = a.objectID.URIRepresentation.absoluteString;
        NSString *ub = b.objectID.URIRepresentation.absoluteString;
        return [ua compare:ub];
    }];
}

#pragma mark - Launch / remote-change sweep (cold + warm path)

- (void)sweep {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

        [self collapseMemoryDuplicatesInContext:ctx];
        [self collapseLeafAndTagDuplicatesInContext:ctx];
        [self healVectorInvariants:ctx];
    });
}

// Memories: a frequency count over the uuid column finds duplicated uuids that
// synced in while nobody was watching (app dead, or a leaf-only merge burst
// the FRC ignored). collapseCandidates re-derives and merges each group.
- (void)collapseMemoryDuplicatesInContext:(NSManagedObjectContext *)ctx {
    // uuid column only — a frequency count, not a table materialization.
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    req.includesSubentities = NO;
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[ @"uuid" ];

    NSError *err = nil;
    NSArray<NSDictionary *> *rows = [ctx executeFetchRequest:req error:&err];
    if (err || !rows) {
        ESLogAlways(@"Deduplicator: sweep fetch failed: %@", err.localizedDescription);
        return;
    }

    NSCountedSet<NSUUID *> *counts = [NSCountedSet set];
    for (NSDictionary *row in rows) {
        NSUUID *u = row[@"uuid"];
        if ([u isKindOfClass:NSUUID.class]) [counts addObject:u];
    }

    NSMutableSet<NSString *> *duplicated = [NSMutableSet set];
    for (NSUUID *u in counts) {
        if ([counts countForObject:u] > 1) [duplicated addObject:u.UUIDString];
    }

    if (duplicated.count > 0) {
        ESLog(@"Deduplicator: sweep found %lu duplicated memory uuid(s)", (unsigned long)duplicated.count);
        [self collapseCandidates:duplicated];
    }
}

// Every non-memory entity, in one save. Leaf entities (CDLink, CDMarginalia,
// CDReference, CDMemoryRevision) collapse by uuid; CDTag collapses by folded
// name, unioning memberships. Memory dedup runs first (above) so children have
// already been re-homed onto surviving memories before we collapse their own
// twins here.
- (void)collapseLeafAndTagDuplicatesInContext:(NSManagedObjectContext *)ctx {
    NSUInteger deleted = 0;
    for (NSString *entity in ESUUIDLeafEntities()) {
        deleted += [self collapseUUIDTwinsForEntity:entity context:ctx];
    }
    deleted += [self collapseTagsInContext:ctx];

    if (deleted > 0) {
        [[ESCoreDataStack shared] saveContext];
        ESLogAlways(@"Deduplicator: collapsed %lu duplicate leaf/tag row%s",
                    (unsigned long)deleted, deleted == 1 ? "" : "s");
    }
}

// Collapse rows of `entityName` sharing a non-nil uuid: keep the survivor,
// delete the twins. CloudKit twins are byte-identical replays, so there is
// nothing to move — the memory merge already re-pointed anything that hung
// off a duplicated memory.
- (NSUInteger)collapseUUIDTwinsForEntity:(NSString *)entityName
                                 context:(NSManagedObjectContext *)ctx {
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:entityName];
    req.includesSubentities = NO;
    NSError *err = nil;
    NSArray<NSManagedObject *> *rows = [ctx executeFetchRequest:req error:&err];
    if (err || !rows) {
        ESLogAlways(@"Deduplicator: %@ scan failed: %@", entityName, err.localizedDescription);
        return 0;
    }

    NSMutableDictionary<NSString *, NSMutableArray<NSManagedObject *> *> *groups = [NSMutableDictionary dictionary];
    for (NSManagedObject *row in rows) {
        id u = [row valueForKey:@"uuid"];
        if (![u isKindOfClass:NSUUID.class]) continue;   // nil uuid → can't identify a twin
        NSString *key = ((NSUUID *)u).UUIDString;
        NSMutableArray *g = groups[key];
        if (!g) { g = [NSMutableArray array]; groups[key] = g; }
        [g addObject:row];
    }

    NSUInteger deleted = 0;
    for (NSString *key in groups) {
        NSArray<NSManagedObject *> *g = groups[key];
        if (g.count < 2) continue;
        NSArray<NSManagedObject *> *sorted = [self sortedByCreationRule:g];
        for (NSUInteger i = 1; i < sorted.count; i++) {
            [ctx deleteObject:sorted[i]];
            deleted++;
        }
    }
    return deleted;
}

// Collapse CDTag rows that fold to the same name. findByName matches
// case- and diacritic-insensitively, so the archive's notion of "same tag"
// folds too — group by the same fold, or two devices that each created
// "Family"/"family" before syncing would keep both rows forever. The merge
// itself is ESTagDedupeMergeGroup — the one rule shared with
// archive_maintenance's dedupeTags, so the automatic and manual paths elect
// the same canonical and fold permanence/kind identically.
- (NSUInteger)collapseTagsInContext:(NSManagedObjectContext *)ctx {
    NSFetchRequest<CDTag *> *req = [NSFetchRequest fetchRequestWithEntityName:@"CDTag"];
    NSError *err = nil;
    NSArray<CDTag *> *tags = [ctx executeFetchRequest:req error:&err];
    if (err || !tags) {
        ESLogAlways(@"Deduplicator: CDTag scan failed: %@", err.localizedDescription);
        return 0;
    }

    NSMutableDictionary<NSString *, NSMutableArray<CDTag *> *> *groups = [NSMutableDictionary dictionary];
    for (CDTag *t in tags) {
        if (t.name.length == 0) continue;
        NSString *key = [t.name stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)
                                                    locale:nil];
        NSMutableArray *g = groups[key];
        if (!g) { g = [NSMutableArray array]; groups[key] = g; }
        [g addObject:t];
    }

    NSUInteger deleted = 0;
    for (NSString *key in groups) {
        NSArray<CDTag *> *g = groups[key];
        if (g.count < 2) continue;
        NSDictionary *counts = ESTagDedupeMergeGroup(g, ctx);
        deleted += [counts[@"deleted"] unsignedIntegerValue];
    }
    return deleted;
}

// CloudKit replay resurrects deleted rows, and the vector pipeline's
// wipe-then-insert pattern turns every resurrection into accumulation
// (July 5 2026: 1,324 memories carried three active-embedder vectors
// across two duplicate CDEmbedder rows). Instead of trusting deletes to
// stick, re-assert the archive's vector invariant at every launch.
//
// The invariant, in the single-universal-embedder world (EmbeddingGemma):
// every CDVector must belong to the ACTIVE embedder and hang off a true
// memory that actually has a summary to embed. Anything else is garbage:
//   - orphan (no memory),
//   - stale (embedderIdentifier != active) — a retired embedder's leftover.
//   - unembeddable (memory has no summary).
//   - surplus (more than one active vector for the same memory) — newest wins.
// Vectors and embedders are pure derived data — recreatable from summaries —
// so nothing here is preserved; the pipeline re-embeds on demand.
- (void)healVectorInvariants:(NSManagedObjectContext *)ctx {
    NSDictionary *embedders = [ESMemoryMaintenanceTool dedupeEmbedders];
    NSUInteger embedderRowsDropped = [embedders[@"rowsDeleted"] unsignedIntegerValue];

    NSString *activeID = [ESVectorEngine summaryEmbedder].identifier;

    NSFetchRequest<CDVector *> *req = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
    NSError *err = nil;
    NSArray<CDVector *> *vectors = [ctx executeFetchRequest:req error:&err];
    if (err || !vectors) {
        ESLogAlways(@"Deduplicator: vector scan failed: %@", err.localizedDescription);
        return;
    }

    NSMutableDictionary<NSString *, CDVector *> *newest = [NSMutableDictionary dictionary];
    NSUInteger purged = 0;
    for (CDVector *v in vectors) {
        CDMemory *m = v.memory;

        // Garbage: orphan, unembeddable memory, or stale embedder.
        // (Guard the stale test on a known activeID so a momentarily
        // unresolved embedder can't nuke the whole vector store.)
        BOOL stale = activeID.length > 0 &&
                     ![(v.embedderIdentifier ?: @"") isEqualToString:activeID];
        if (!m || m.summary.length == 0 || stale) {
            [ctx deleteObject:v];
            purged++;
            continue;
        }

        // One active vector per memory — newest wins.
        NSString *key = m.objectID.URIRepresentation.absoluteString;
        CDVector *kept = newest[key];
        if (!kept) { newest[key] = v; continue; }

        NSDate *dv = v.dateCreated ?: NSDate.distantPast;
        NSDate *dk = kept.dateCreated ?: NSDate.distantPast;
        if ([dv compare:dk] == NSOrderedDescending) {
            [ctx deleteObject:kept];
            newest[key] = v;
        } else {
            [ctx deleteObject:v];
        }
        purged++;
    }

    if (purged > 0 || embedderRowsDropped > 0) {
        [[ESCoreDataStack shared] saveContext];
        ESLogAlways(@"Deduplicator: healed vector invariants — %lu surplus/stale vector%s purged, %lu duplicate embedder row%s collapsed",
                    (unsigned long)purged, purged == 1 ? "" : "s",
                    (unsigned long)embedderRowsDropped, embedderRowsDropped == 1 ? "" : "s");
    }
}

@end
