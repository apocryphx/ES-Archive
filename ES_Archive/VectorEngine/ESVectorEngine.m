//
//  ESVectorEngine.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESVectorEngine.h"
#import "ESVectorCacheEntry.h"
#import "ESVectorSearchResult.h"
#import "ESCoreDataStack.h"
#import "ESLog.h"
#import "ESTopKScores.h"
#import "CDMemory.h"
#import "CDVector.h"
#import "CDVector+CoreDataProperties.h"
#import "CDEmbedder.h"
#import "CDEmbedder+CoreDataProperties.h"
#import "ESSummaryEmbedder.h"
#import <stdatomic.h>

@import Accelerate;

NSNotificationName const ESVectorCacheReadyNotification = @"ESVectorCacheReady";

@interface ESVectorEngine () <NSFetchedResultsControllerDelegate> {
    dispatch_queue_t _isolationQueue;
    // Number of completion-fence ops outstanding on _vectorQueue. Bumped
    // before enqueueing a fence (a no-op block whose only job is to fire a
    // caller's completion handler after all real work drains), decremented
    // inside that fence block. Subtracted from `operationCount` in the
    // public `pendingVectorOperations` getter so the surface reports real
    // work only — fence ops are an implementation detail of how completion
    // is sequenced on the serial queue. Atomic int access since the fence
    // block runs on the queue's worker thread while the getter runs on
    // arbitrary callers.
    atomic_int _pendingFenceOps;
}

@property (nonatomic, strong) NSMutableDictionary<NSManagedObjectID *, ESVectorCacheEntry *> *vectorDataDictionary;
@property (nonatomic, strong) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic, strong) NSOperationQueue *vectorQueue;
@property (nonatomic) NSUInteger dimension;

/// Active summary embedder — a single universal model, resolved once at
/// init via ESSummaryEmbedderForCurrentLocale() and fixed for the session.
/// Nil only when no ESSummaryEmbedder-conforming class is registered.
@property (nonatomic, strong, nullable) id<ESSummaryEmbedder> summaryEmbedder;

@end

@implementation ESVectorEngine

#pragma mark - Singleton

+ (instancetype)shared {
    static ESVectorEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ESVectorEngine alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _vectorDataDictionary = [NSMutableDictionary dictionary];
        _isolationQueue = dispatch_queue_create("com.esarchive.vectorengine.isolation", DISPATCH_QUEUE_CONCURRENT);
        _dimension = 0;

        _vectorQueue = [[NSOperationQueue alloc] init];
        _vectorQueue.maxConcurrentOperationCount = 1;
        _vectorQueue.name = @"com.esarchive.vectorengine.vectorqueue";
        _vectorQueue.qualityOfService = NSQualityOfServiceUtility;

        // Pick the summary embedder for the device locale. Bundled assets
        // load lazily on first encode; this call only walks the registry.
        _summaryEmbedder = ESSummaryEmbedderForCurrentLocale();
        if (!_summaryEmbedder) {
            NSLog(@"ESVectorEngine: no summary embedder registered — "
                  @"check that EmbeddingGemmaEmbedder is linked and its assets "
                  @"are bundled");
        }

        // Orphan key from when decayLevel was a persisted global. Decay is
        // now strictly a per-call retrieval knob (archive_search/discover's
        // `focus` argument). Safe to drop on first launch after this change.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ESVectorEngineDecayLevel"];

        // Orphan keys from the v1 multi-embedder preference layer.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ESVectorEngine.preferredEmbedderIdentifier"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ESVectorEngine.heuristicEmbedderIdentifier"];
    }
    return self;
}

+ (NSArray<NSString *> *)decayLevels {
    return @[@"day", @"week", @"month", @"none"];
}

+ (NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *)decayPresets {
    static NSDictionary *presets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presets = @{
            @"day":   @{@"d": @0.855f, @"slope": @3.19f, @"shift": @(-10.0f), @"period": @1.0f},
            @"week":  @{@"d": @0.7f,   @"slope": @2.15f, @"shift": @(-9.0f),  @"period": @7.0f},
            @"month": @{@"d": @0.3f,   @"slope": @1.0f,  @"shift": @(3.0f),   @"period": @30.0f},
            @"none":  @{@"d": @0.0f,   @"slope": @0.0f,  @"shift": @(0.0f),   @"period": @0.0f}
        };
    });
    return presets;
}

+ (NSDictionary<NSString *, NSString *> *)decayLevelDescriptions {
    static NSDictionary *descs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        descs = @{
            @"day":   @"day — today's session, full presence.",
            @"week":  @"week — the current sprint.",
            @"month": @"month — the full project arc.",
            @"none":  @"none — pure cosine, the full landscape."
        };
    });
    return descs;
}

+ (NSString *)defaultDecayLevel {
    return @"none";
}

/// Build a cache entry from a CDVector. Validates dimension consistency,
/// setting self.dimension on first vector. Returns nil if data is invalid
/// or dimension mismatches. Must be called inside _isolationQueue barrier.
- (nullable ESVectorCacheEntry *)cacheEntryFromVector:(CDVector *)vector {
    NSData *data = vector.data;
    if (!data || data.length == 0 || data.length % sizeof(float) != 0) {
        return nil;
    }

    NSUInteger vectorDim = data.length / sizeof(float);
    if (self.dimension == 0) {
        self.dimension = vectorDim;
    } else if (vectorDim != self.dimension) {
        return nil;
    }

    NSTimeInterval lastTs = vector.lastAccessed
        ? [vector.lastAccessed timeIntervalSinceReferenceDate] : 0.0;
    NSTimeInterval createTs = vector.dateCreated
        ? [vector.dateCreated timeIntervalSinceReferenceDate] : 0.0;

    return [[ESVectorCacheEntry alloc]
        initWithVectorData:data
               accessCount:(NSUInteger)vector.accessCount
      lastAccessedTimestamp:lastTs
         creationTimestamp:createTs];
}

#pragma mark - Cache Warm

- (void)warmCache {
    // The summary embedder loads its model + tokenizer lazily on first
    // encode call. No upfront preload needed here.
    [self backfillMemoryLanguage];
    [self setupFetchedResultsController];
    [self loadInitialCache];

    NSDictionary *stale = [self staleVectorReport];
    NSUInteger count = [stale[@"count"] unsignedIntegerValue];
    if (count > 0) {
        ESLog(@"ESVectorEngine: %lu stale vector(s) detected (from %@). "
              @"The launch heal purges these automatically; "
              @"archive_maintenance(reindexSummaries) forces it now.",
              (unsigned long)count, stale[@"embedderIDs"]);
    }
}

/// One-time backfill: any CDMemory with nil `language` predates the schema
/// migration. Stamp them with English. Idempotent — subsequent launches
/// find zero unlabeled rows and exit in O(1).
///
/// Empirically grounded: the May 6 NLLanguageRecognizer eval established
/// that the existing 587-memory corpus is ~98% English. The 2%
/// misclassifications were systematically Latin-script languages on
/// English content with proper nouns / code identifiers. Defaulting to
/// the active embedder's language is more accurate than running
/// NLLanguageRecognizer over legacy rows.
- (void)backfillMemoryLanguage {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *req = [CDMemory fetchRequest];
    req.includesSubentities = NO; // CDMemoryRevision shares the table; snapshots keep their language
    req.predicate = [NSPredicate predicateWithFormat:@"language == nil"];

    NSError *fetchErr = nil;
    NSArray<CDMemory *> *unlabeled = [ctx executeFetchRequest:req error:&fetchErr];
    if (fetchErr) {
        NSLog(@"ESVectorEngine: language backfill fetch failed: %@", fetchErr);
        return;
    }
    if (unlabeled.count == 0) return;

    NSString *def = self.summaryEmbedder.language ?: @"en";
    for (CDMemory *m in unlabeled) {
        m.language = def;
    }

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        NSLog(@"ESVectorEngine: language backfill save failed: %@", saveErr);
        return;
    }

    ESLog(@"ESVectorEngine: backfilled language=%@ on %lu legacy memories",
          def, (unsigned long)unlabeled.count);
}

/// Tear down the in-memory cache + FRC and rebuild them from the store.
/// Called after a bulk vector change (erase / reindex) so the cache and
/// its readers pick up the new rows; posts ESVectorCacheReadyNotification
/// when done. Safe to call from any thread — dispatches to main if needed
/// because Core Data fetch / FRC operations require it.
- (void)reloadVectorCache {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadVectorCache];
        });
        return;
    }

    id<ESSummaryEmbedder> active = self.summaryEmbedder;
    ESLog(@"ESVectorEngine: rebuilding cache for summary embedder %@ (dim=%lu)",
          active.identifier ?: @"<none>",
          (unsigned long)active.vectorDimension);

    _fetchedResultsController.delegate = nil;
    _fetchedResultsController = nil;

    dispatch_barrier_sync(_isolationQueue, ^{
        [self.vectorDataDictionary removeAllObjects];
        self.dimension = 0;
    });

    [self setupFetchedResultsController];
    [self loadInitialCache];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:ESVectorCacheReadyNotification
                      object:self
                    userInfo:@{@"count": @(self.vectorDataDictionary.count)}];

    // Ensure a CDEmbedder inventory row exists for this embedder. Presence
    // is explicit in the data model, not just implied by vector existence.
    if (active) {
        NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
        (void)[CDEmbedder findOrCreateWithIdentifier:active.identifier
                                            dimension:active.vectorDimension
                                            inContext:ctx];
        NSError *saveErr = nil;
        if (![ctx save:&saveErr]) {
            NSLog(@"ESVectorEngine: CDEmbedder inventory save failed: %@", saveErr);
        }
    }
}

- (void)setupFetchedResultsController {
    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;

    // Filter to vectors produced by the active summary embedder. Stale
    // vectors from a previous embedder remain in the database but don't
    // enter the retrieval cache — they're surfaced via staleVectorReport
    // and removed by an explicit maintenance call.
    id<ESSummaryEmbedder> active = self.summaryEmbedder;
    NSString *activeID = active.identifier;

    NSFetchRequest *request = [CDVector fetchRequest];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"memory.dateCreated" ascending:NO]];
    if (activeID) {
        request.predicate = [NSPredicate predicateWithFormat:@"embedder.identifier == %@", activeID];
    } else {
        // No active embedder — this is a degraded state, but build an empty
        // cache rather than crashing. warmCache will re-run when an embedder
        // becomes available.
        request.predicate = [NSPredicate predicateWithFormat:@"FALSEPREDICATE"];
    }

    _fetchedResultsController = [[NSFetchedResultsController alloc] initWithFetchRequest:request
                                                                    managedObjectContext:context
                                                                      sectionNameKeyPath:nil
                                                                               cacheName:nil];
    _fetchedResultsController.delegate = self;

    NSError *error = nil;
    if (![_fetchedResultsController performFetch:&error]) {
        NSLog(@"ESVectorEngine: FRC fetch failed: %@", error);
    }

    // Set the cache's expected dimension authoritatively from the active
    // embedder, rather than auto-detecting from the first vector. This
    // catches dimension mismatches between active embedder and stored
    // vectors at validation time inside cacheEntryFromVector:.
    if (active) {
        self.dimension = active.vectorDimension;
    }
}

- (void)loadInitialCache {
    NSAssert([NSThread isMainThread], @"loadInitialCache must be called on main thread");
    NSArray<CDVector *> *vectors = self.fetchedResultsController.fetchedObjects;

    dispatch_barrier_sync(_isolationQueue, ^{
        for (CDVector *vector in vectors) {
            // Skip vectors belonging to CDMemoryRevision
            if (!vector.memory || [vector.memory isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
                continue;
            }

            ESVectorCacheEntry *entry = [self cacheEntryFromVector:vector];
            if (entry) {
                self.vectorDataDictionary[vector.objectID] = entry;
            }
        }

        NSUInteger count = self.vectorDataDictionary.count;
        if (count > 0) {
            double memoryMB = (double)(count * self.dimension * sizeof(float)) / (1024.0 * 1024.0);
            ESLog(@"ESVectorEngine: loaded %lu vectors (~%.1f MB)", (unsigned long)count, memoryMB);
        } else {
            ESLog(@"ESVectorEngine: cache empty (no vectors yet)");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:ESVectorCacheReadyNotification
                              object:self
                            userInfo:@{ @"count": @(count) }];
        });
    });
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {

    CDVector *vector = (CDVector *)anObject;
    NSManagedObjectID *objID = vector.objectID;

    NSString *changeLabel = (type == NSFetchedResultsChangeInsert) ? @"insert" :
                             (type == NSFetchedResultsChangeUpdate) ? @"update" :
                             (type == NSFetchedResultsChangeDelete) ? @"delete" : @"move";

    ESLog(@"[VectorCache] FRC delegate fired: %@ objID=%@ main=%d",
          changeLabel, objID, [NSThread isMainThread]);

    // Materialize Core Data properties on the main thread (where the FRC fires)
    // BEFORE dispatching to the background isolation queue. Avoids faulting
    // managed objects from a background queue — critical for bulk reindex where
    // vectors arrive as unfired faults from a child context push.
    NSData *vectorData = nil;
    NSUInteger accessCount = 0;
    NSTimeInterval lastAccessedTs = 0.0;
    NSTimeInterval creationTs = 0.0;
    if (type == NSFetchedResultsChangeInsert || type == NSFetchedResultsChangeUpdate) {
        vectorData = vector.data;
        ESLog(@"[VectorCache] materialized data: %lu bytes, isFault=%d",
              (unsigned long)vectorData.length, vector.isFault);
        accessCount = (NSUInteger)vector.accessCount;
        lastAccessedTs = vector.lastAccessed
            ? [vector.lastAccessed timeIntervalSinceReferenceDate] : 0.0;
        creationTs = vector.dateCreated
            ? [vector.dateCreated timeIntervalSinceReferenceDate] : 0.0;
    }

    dispatch_barrier_async(_isolationQueue, ^{
        switch (type) {
            case NSFetchedResultsChangeInsert:
            case NSFetchedResultsChangeUpdate: {
                if (vectorData && vectorData.length > 0 && vectorData.length % sizeof(float) == 0) {
                    NSUInteger vectorDim = vectorData.length / sizeof(float);
                    if (self.dimension == 0) {
                        self.dimension = vectorDim;
                    } else if (vectorDim != self.dimension) {
                        NSLog(@"[VectorCache] dimension mismatch: expected %lu, got %lu",
                              (unsigned long)self.dimension, (unsigned long)vectorDim);
                        break;
                    }
                    ESVectorCacheEntry *entry = [[ESVectorCacheEntry alloc]
                        initWithVectorData:vectorData
                               accessCount:accessCount
                      lastAccessedTimestamp:lastAccessedTs
                         creationTimestamp:creationTs];
                    self.vectorDataDictionary[objID] = entry;
                    ESLog(@"[VectorCache] %@ — cache now has %lu vectors (%lu-dim)",
                          changeLabel, (unsigned long)self.vectorDataDictionary.count,
                          (unsigned long)self.dimension);
                } else {
                    [self.vectorDataDictionary removeObjectForKey:objID];
                }
                break;
            }
            case NSFetchedResultsChangeDelete:
                [self.vectorDataDictionary removeObjectForKey:objID];
                // Reset dimension when cache empties (e.g. during reindex) so the
                // first new vector can establish a fresh dimension if the embedding
                // model changed.
                if (self.vectorDataDictionary.count == 0) {
                    self.dimension = 0;
                }
                ESLog(@"[VectorCache] delete — cache now has %lu vectors",
                      (unsigned long)self.vectorDataDictionary.count);
                break;
            default:
                break;
        }
    });
}

#pragma mark - Embedder Slot

/// The active summary embedder. Resolved at init via
/// ESSummaryEmbedderForCurrentLocale() and cached on the singleton.
+ (id<ESSummaryEmbedder>)summaryEmbedder {
    return [ESVectorEngine shared].summaryEmbedder;
}

#pragma mark - Embedding Generation

+ (NSData *)vectorDataFromString:(NSString *)flatText {
    return [self vectorDataFromString:flatText title:nil task:ESEmbeddingTaskDocument];
}

+ (NSData *)vectorDataFromString:(NSString *)flatText task:(ESEmbeddingTask)task {
    return [self vectorDataFromString:flatText title:nil task:task];
}

+ (NSData *)vectorDataFromString:(NSString *)flatText
                           title:(NSString *)title
                            task:(ESEmbeddingTask)task {
    if (flatText.length == 0) return nil;
    id<ESSummaryEmbedder> embedder = [self summaryEmbedder];
    if (!embedder) return nil;
    NSError *err = nil;
    NSData *vec = [embedder encodeString:flatText title:title task:task error:&err];
    if (!vec && err) {
        NSLog(@"ESVectorEngine: encode failed: %@", err.localizedDescription);
    }
    return vec;
}

#pragma mark - Vector Queue

- (NSUInteger)pendingVectorOperations {
    NSUInteger total = self.vectorQueue.operationCount;
    int fences = atomic_load_explicit(&_pendingFenceOps, memory_order_relaxed);
    if (fences < 0) fences = 0;
    return total > (NSUInteger)fences ? total - (NSUInteger)fences : 0;
}

- (void)enqueueVectorForMemory:(CDMemory *)memory {
    NSManagedObjectID *memoryID = memory.objectID;
    NSString *title = memory.title ?: @"(untitled)";

    // Summary-only input. Title is never included — summary is curated
    // English prose; titles are user-authored and may be in any language.
    // A memory with no summary cannot be embedded — and must therefore hold
    // NO vector. Historically this branch just returned, so a memory that
    // lost (or never had) a summary kept whatever vectors it carried forever,
    // including retired-embedder leftovers the migration wipe never reached.
    // Delete them here so "no summary ⇒ no vector" holds at the source, not
    // only at the launch heal.
    NSString *embeddingText = memory.summary;
    if (embeddingText.length == 0) {
        ESLog(@"[VectorQueue] '%@' has no summary — clearing any existing vectors", title);
        NSManagedObjectContext *mctx = memory.managedObjectContext;
        if (memory.vectors.count > 0) {
            for (CDVector *v in [memory.vectors copy]) {
                [mctx deleteObject:v];
            }
            NSError *saveErr = nil;
            [mctx save:&saveErr];
            if (saveErr) NSLog(@"[VectorQueue] vector-clear save failed for '%@': %@", title, saveErr);
        }
        return;
    }

    if (memoryID.isTemporaryID) {
        [memory.managedObjectContext obtainPermanentIDsForObjects:@[memory] error:nil];
        memoryID = memory.objectID;
    }

    NSManagedObjectID *capturedID = memoryID;
    NSString *memoryLanguage = memory.language.length > 0 ? memory.language : @"en";
    NSString *embeddingTitle = memory.title;   // real title → document prompt

    ESLog(@"[VectorQueue] enqueued '%@' (queue depth: %lu)",
          title, (unsigned long)(self.vectorQueue.operationCount + 1));

    [self.vectorQueue addOperationWithBlock:^{
        ESLog(@"[VectorQueue] generating embedding for '%@'...", title);

        NSData *vectorData = [ESVectorEngine vectorDataFromString:embeddingText
                                                            title:embeddingTitle
                                                             task:ESEmbeddingTaskDocument];
        if (!vectorData) {
            ESLog(@"[VectorQueue] embedding failed for '%@'", title);
            return;
        }

        NSUInteger dim = vectorData.length / sizeof(float);
        ESLog(@"[VectorQueue] '%@' — %lu dimensions", title, (unsigned long)dim);

        dispatch_sync(dispatch_get_main_queue(), ^{
            NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
            CDMemory *mem = [ctx objectWithID:capturedID];
            if (!mem) {
                ESLog(@"[VectorQueue] memory gone for '%@'", title);
                return;
            }

            // Wipe every existing CDVector for this memory. With a single
            // active summary embedder per archive, any pre-existing rows
            // either describe an older summary (stale) or were produced by
            // a previous embedder (also stale).
            id<ESSummaryEmbedder> embedder = [ESVectorEngine summaryEmbedder];
            for (CDVector *v in [mem.vectors copy]) {
                [ctx deleteObject:v];
            }

            CDVector *newVector = [NSEntityDescription insertNewObjectForEntityForName:@"CDVector"
                                                               inManagedObjectContext:ctx];
            CDEmbedder *embedderEntity = [CDEmbedder findOrCreateWithIdentifier:embedder.identifier
                                                                       dimension:embedder.vectorDimension
                                                                       inContext:ctx];
            [embedderEntity touchDateLastUsed];
            newVector.data = vectorData;
            newVector.dateCreated = [NSDate now];
            newVector.accessCount = mem.accessCount;
            newVector.lastAccessed = mem.dateAccessed;
            newVector.embedderIdentifier = embedder.identifier;
            newVector.embedder = embedderEntity;
            newVector.language = memoryLanguage;
            [mem addVectorsObject:newVector];

            [ctx obtainPermanentIDsForObjects:@[newVector] error:nil];

            NSError *saveError = nil;
            [ctx save:&saveError];
            if (saveError) {
                NSLog(@"[VectorQueue] save failed for '%@': %@", title, saveError);
            } else {
                ESLog(@"[VectorQueue] '%@' saved", title);
            }
        });
    }];
}

#pragma mark - Scoring

//  Decay-weighted scoring: cosine similarity gated by a sigmoid recency curve.
//
//      score = cosine * sigmoid(t)
//
//  where t = days since last access.
//  sigmoid = floor + (1-floor) / (1 + exp(k * (t - mid)))
//  k = d * slope, mid = max(0, 10/d + shift), floor = 0.20.
//
//  Presets are temporal horizons — each a tuned sigmoid:
//    day:   d=0.855, slope=3.19, shift=-10, period=1   (today's session)
//    week:  d=0.7,   slope=2.15, shift=-9,  period=7   (the current sprint)
//    month: d=0.3,   slope=1.0,  shift=+3,  period=30  (the full project arc)
//    none:  pure cosine (no scoring applied)
//
//  Design decisions:
//
//  1. Sigmoid, not power-law or exponential. The sigmoid (Sheep Hill Curve,
//     inspired by Hurter & Driffield film characteristic curves) gives a
//     grace period (shoulder) where recent memories stay at full strength,
//     a smooth transition zone, and a floor where old memories settle but
//     never vanish. The floor (0.20) ensures even forgotten memories still
//     have a voice when semantically relevant.
//
//  2. lastAccessed, not dateCreated. A 365-day-old memory accessed yesterday
//     should score high. Falls back to creationTimestamp if never accessed.
//
//  3. Frequency boost (log1p) was removed (March 9, 2026). Even with
//     d-scaling, access counts created feedback loops: accessed memories
//     surfaced more, got accessed more, became universal hubs. The
//     Einstellung effect as math.
//
//  4. Sentiment scoring removed (April 8, 2026). NLTagger's sentiment
//     classifier produced near-constant output on this corpus (paragraph
//     probe: five distinct summaries all returned -0.6). The signal was
//     noise, the one mode that depended on it (`traumatic`) was already
//     structurally broken, and removing it simplifies the engine without
//     loss. The wine cellar doesn't need a mood ring.
//
//  5. d=0 returns pure cosine — the unfiltered semantic landscape.

- (float)weightedScore:(float)cosineSimilarity
              forEntry:(ESVectorCacheEntry *)entry
            decayLevel:(NSString *)decayLevel {
    NSDictionary *preset = [[self class] decayPresets][decayLevel];
    float d = [preset[@"d"] floatValue];
    if (d == 0.0f) return cosineSimilarity;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    float daysSinceAccess;
    if (entry.lastAccessedTimestamp == 0.0) {
        daysSinceAccess = (float)((now - entry.creationTimestamp) / 86400.0);
    } else {
        daysSinceAccess = (float)((now - entry.lastAccessedTimestamp) / 86400.0);
        if (daysSinceAccess < 0.0f) daysSinceAccess = 0.0f;
    }

    float slope = [preset[@"slope"] floatValue];
    float shift = [preset[@"shift"] floatValue];

    float recencyFactor = [self sigmoidRecency:daysSinceAccess
                                          rate:d slope:slope
                                         shift:shift];
    return cosineSimilarity * recencyFactor;
}

/// Sigmoid recency factor — Sheep Hill Curve (H&D film characteristic curve).
/// Grace period (shoulder): recent memories stay at full strength.
/// Transition: smooth drop tuned by d × slope.
/// Floor (0.20): old memories settle at 20% weight, never vanish.
/// Mid clamped to ≥0 so the sigmoid never inverts.
- (float)sigmoidRecency:(float)t rate:(float)d slope:(float)slope shift:(float)shift {
    static const float kFloor = 0.20f;
    float mid = fmaxf(0.0f, 10.0f / fmaxf(d, 0.001f) + shift);
    float k = d * slope;
    float s = 1.0f / (1.0f + expf(k * (t - mid)));
    return kFloor + (1.0f - kFloor) * s;
}

#pragma mark - Access Tracking Push

- (void)pushAccessStatsForMemory:(CDMemory *)memory {
    // Push access stats to the active-embedder vector for this memory.
    // Other embedders' vectors retain their own access stats from when those
    // embedders were active — leaving them stale on switch is correct;
    // they'll be refreshed when/if that embedder becomes active again.
    CDVector *vector = [memory vectorForActiveEmbedder];
    if (!vector) return;

    NSManagedObjectID *vectorID = vector.objectID;
    if (vectorID.isTemporaryID) return;

    // Update CDVector entity (caller already saved context)
    vector.accessCount = memory.accessCount;
    vector.lastAccessed = memory.dateAccessed;

    // Update cache entry
    NSUInteger newAccessCount = (NSUInteger)memory.accessCount;
    NSTimeInterval newTimestamp = memory.dateAccessed
        ? [memory.dateAccessed timeIntervalSinceReferenceDate] : 0.0;

    dispatch_barrier_async(_isolationQueue, ^{
        ESVectorCacheEntry *existing = self.vectorDataDictionary[vectorID];
        if (existing) {
            existing.accessCount = newAccessCount;
            existing.lastAccessedTimestamp = newTimestamp;
        }
    });
}

#pragma mark - Search

- (NSArray<ESVectorSearchResult *> *)topK:(NSUInteger)k forQuery:(NSData *)queryVectorData {
    return [self topK:k forQuery:queryVectorData decayLevel:nil allowedVectorIDs:nil];
}

- (NSArray<ESVectorSearchResult *> *)topK:(NSUInteger)k
                                 forQuery:(NSData *)queryVectorData
                               decayLevel:(NSString *)decayLevel
                         allowedVectorIDs:(NSSet<NSManagedObjectID *> *)allowed {
    if (!queryVectorData || queryVectorData.length == 0) return @[];
    if (queryVectorData.length % sizeof(float) != 0) return @[];

    // Decay is a per-call retrieval knob (the `focus` parameter on
    // archive_search / archive_discover). nil means "no override given" —
    // fall back to the engine default (currently "none" → pure cosine).
    NSString *effectiveDecay = decayLevel ?: [[self class] defaultDecayLevel];

    NSUInteger queryDim = queryVectorData.length / sizeof(float);

    __block NSUInteger cacheDimension = 0;
    __block NSUInteger cacheCount = 0;
    dispatch_sync(_isolationQueue, ^{
        cacheDimension = self.dimension;
        cacheCount = self.vectorDataDictionary.count;
    });

    ESLog(@"[Search] query=%lu-dim, cache=%lu vectors, cacheDim=%lu",
          (unsigned long)queryDim, (unsigned long)cacheCount, (unsigned long)cacheDimension);

    if (cacheDimension != 0 && queryDim != cacheDimension) {
        NSLog(@"ESVectorEngine: dimension mismatch (query %lu vs cache %lu)",
              (unsigned long)queryDim, (unsigned long)cacheDimension);
        return @[];
    }

    // Snapshot for lock-free enumeration
    __block NSDictionary *snapshot;
    dispatch_sync(_isolationQueue, ^{
        snapshot = [self.vectorDataDictionary copy];
    });

    if (snapshot.count == 0) return @[];

    // Phase 1: SIMD dot product + gatekeeper
    const float *queryVec = (const float *)queryVectorData.bytes;
    ESTopKScores *tracker = [[ESTopKScores alloc] initWithCapacity:k];

    void (^scoreEntry)(NSManagedObjectID *, ESVectorCacheEntry *) = ^(NSManagedObjectID *objID, ESVectorCacheEntry *entry) {
        NSData *blob = entry.vectorData;
        NSUInteger len = blob.length / sizeof(float);
        if (len != queryDim) return;

        const float *vec = (const float *)blob.bytes;
        float cosine = 0.0f;
        vDSP_dotpr(queryVec, 1, vec, 1, &cosine, len);

        float score = [self weightedScore:cosine forEntry:entry
                                decayLevel:effectiveDecay];
        // Carry the pre-decay cosine alongside the decayed score so callers
        // that want an absolute-similarity threshold (w2vgrep --threshold)
        // can apply it without re-computing.
        [tracker addScore:score cosine:cosine forObjectID:objID];
    };

    if (allowed) {
        // Filtered: iterate the allowed set and look up each entry in the snapshot.
        // O(|allowed|) instead of O(|snapshot|).
        for (NSManagedObjectID *objID in allowed) {
            ESVectorCacheEntry *entry = snapshot[objID];
            if (!entry) continue;
            scoreEntry(objID, entry);
        }
    } else {
        [snapshot enumerateKeysAndObjectsUsingBlock:^(NSManagedObjectID *objID, ESVectorCacheEntry *entry, BOOL *stop) {
            scoreEntry(objID, entry);
        }];
    }

    NSArray<NSDictionary *> *topEntries = [tracker topEntries];
    if (topEntries.count == 0) return @[];

    NSMutableArray<NSManagedObjectID *> *topIDs = [NSMutableArray arrayWithCapacity:topEntries.count];
    for (NSDictionary *dict in topEntries) {
        [topIDs addObject:dict[@"objectID"]];
    }

    // Phase 2: Hydrate
    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *fetchRequest = [CDVector fetchRequest];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"self IN %@", topIDs];
    fetchRequest.relationshipKeyPathsForPrefetching = @[@"memory"];

    NSError *error = nil;
    NSArray<CDVector *> *topVectors = [context executeFetchRequest:fetchRequest error:&error];
    if (error) {
        NSLog(@"ESVectorEngine: hydration fetch failed: %@", error);
        return @[];
    }

    NSMutableDictionary<NSManagedObjectID *, CDVector *> *vectorMap = [NSMutableDictionary dictionaryWithCapacity:topVectors.count];
    for (CDVector *v in topVectors) {
        vectorMap[v.objectID] = v;
    }

    // Phase 3: Map to results (raw scores)
    NSMutableArray<ESVectorSearchResult *> *finalResults = [NSMutableArray arrayWithCapacity:topEntries.count];
    for (NSDictionary *entry in topEntries) {
        NSManagedObjectID *objID = entry[@"objectID"];
        CDVector *vector = vectorMap[objID];
        if (vector && vector.memory) {
            ESVectorSearchResult *result = [ESVectorSearchResult new];
            result.memory = (CDMemory *)vector.memory;
            result.rawScore = [entry[@"score"] floatValue];
            result.cosine = [entry[@"cosine"] floatValue];
            [finalResults addObject:result];
        }
    }

    // Phase 4: surface r.score = pre-decay cosine. rawScore is the
    // decay-weighted cosine used for ranking; the user-visible score is the
    // raw similarity, since decay would conflate similarity with recency.
    for (ESVectorSearchResult *r in finalResults) {
        r.score = r.cosine;
    }

    return finalResults;
}

- (NSArray<NSDictionary *> *)topKSimilarToVector:(NSData *)vector
                                           limit:(NSInteger)limit
                                  excludingTitle:(NSString *)excludedTitle {
    return [self topKSimilarToVector:vector limit:limit excludingTitle:excludedTitle allowedVectorIDs:nil];
}

- (NSArray<NSDictionary *> *)topKSimilarToVector:(NSData *)vector
                                           limit:(NSInteger)limit
                                  excludingTitle:(NSString *)excludedTitle
                                allowedVectorIDs:(NSSet<NSManagedObjectID *> *)allowed {

    if (!vector || vector.length == 0) return @[];
    if (vector.length % sizeof(float) != 0) return @[];

    NSUInteger queryDim = vector.length / sizeof(float);

    __block NSUInteger cacheDimension = 0;
    dispatch_sync(_isolationQueue, ^{
        cacheDimension = self.dimension;
    });

    if (cacheDimension != 0 && queryDim != cacheDimension) return @[];

    // Snapshot for lock-free enumeration
    __block NSDictionary *snapshot;
    dispatch_sync(_isolationQueue, ^{
        snapshot = [self.vectorDataDictionary copy];
    });

    if (snapshot.count == 0) return @[];

    // SIMD dot product with threshold gate — extra slot for potential self-match
    const float *queryVec = (const float *)vector.bytes;
    ESTopKScores *tracker = [[ESTopKScores alloc] initWithCapacity:limit + 1];

    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSManagedObjectID *objID, ESVectorCacheEntry *entry, BOOL *stop) {
        // Persona scope: skip vectors outside the allowed set when provided.
        if (allowed && ![allowed containsObject:objID]) return;
        NSData *blob = entry.vectorData;
        NSUInteger len = blob.length / sizeof(float);
        if (len != queryDim) return;

        const float *vec = (const float *)blob.bytes;
        float cosine = 0.0f;
        vDSP_dotpr(queryVec, 1, vec, 1, &cosine, len);
        float score = [self weightedScore:cosine forEntry:entry
                                decayLevel:[ESVectorEngine defaultDecayLevel]];
        [tracker addScore:score cosine:cosine forObjectID:objID];

    }];

    NSArray<NSDictionary *> *topEntries = [tracker topEntries];
    if (topEntries.count == 0) return @[];

    // Hydrate to get titles
    NSMutableArray<NSManagedObjectID *> *topIDs = [NSMutableArray arrayWithCapacity:topEntries.count];
    for (NSDictionary *dict in topEntries) {
        [topIDs addObject:dict[@"objectID"]];
    }

    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *fetchRequest = [CDVector fetchRequest];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"self IN %@", topIDs];
    fetchRequest.relationshipKeyPathsForPrefetching = @[@"memory"];

    NSError *error = nil;
    NSArray<CDVector *> *topVectors = [context executeFetchRequest:fetchRequest error:&error];
    if (error) return @[];

    NSMutableDictionary<NSManagedObjectID *, NSString *> *titleMap =
        [NSMutableDictionary dictionaryWithCapacity:topVectors.count];
    for (CDVector *v in topVectors) {
        if (v.memory) {
            titleMap[v.objectID] = v.memory.title ?: @"Untitled";
        }
    }

    // Filter by excluded title and build results (raw scores)
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (NSDictionary *entry in topEntries) {
        if ((NSInteger)results.count >= limit) break;

        NSManagedObjectID *objID = entry[@"objectID"];
        NSString *title = titleMap[objID];
        if (!title) continue;

        if ([title caseInsensitiveCompare:excludedTitle] == NSOrderedSame) continue;

        [results addObject:@{
            @"title": title,
            @"rawScore": entry[@"score"]
        }];
    }

    // Surface score = raw cosine. No transformation.
    if (results.count > 0) {
        NSMutableArray *rescaled = [NSMutableArray arrayWithCapacity:results.count];
        for (NSDictionary *r in results) {
            float raw = [r[@"rawScore"] floatValue];
            [rescaled addObject:@{
                @"title": r[@"title"],
                @"score": @(raw),
                @"rawScore": @(raw)
            }];
        }
        return rescaled;
    }

    return results;
}

- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query limit:(NSUInteger)k {
    return [self searchWithQuery:query limit:k decayLevel:nil allowedVectorIDs:nil];
}

- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query
                                               limit:(NSUInteger)k
                                          decayLevel:(NSString *)decayLevel {
    return [self searchWithQuery:query
                           limit:k
                      decayLevel:decayLevel
                allowedVectorIDs:nil];
}

- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query
                                               limit:(NSUInteger)k
                                          decayLevel:(NSString *)decayLevel
                                    allowedVectorIDs:(NSSet<NSManagedObjectID *> *)allowed {
    // Embed as a QUERY — EmbeddingGemma applies the retrieval query prefix,
    // distinct from the document prefix used when memory summaries are indexed.
    // Query and memory vectors still live in the same model space, so cosines
    // between them are meaningful.
    NSData *queryVector = [ESVectorEngine vectorDataFromString:query task:ESEmbeddingTaskQuery];
    if (!queryVector) return @[];
    return [self topK:k
             forQuery:queryVector
           decayLevel:decayLevel
     allowedVectorIDs:allowed];
}

- (NSArray<ESVectorSearchResult *> *)similarToMemory:(CDMemory *)memory limit:(NSUInteger)k {
    CDVector *v = [memory vectorForActiveEmbedder];
    if (!v || !v.data) return @[];
    return [self topK:k forQuery:v.data];
}

- (NSArray<ESVectorSearchResult *> *)similarToMemory:(CDMemory *)memory
                                               limit:(NSUInteger)k
                                    allowedVectorIDs:(NSSet<NSManagedObjectID *> *)allowed {
    CDVector *v = [memory vectorForActiveEmbedder];
    if (!v || !v.data) return @[];
    return [self topK:k forQuery:v.data decayLevel:nil allowedVectorIDs:allowed];
}

- (NSArray<ESVectorSearchResult *> *)cosineSimilarToMemory:(CDMemory *)memory limit:(NSUInteger)k {
    CDVector *v = [memory vectorForActiveEmbedder];
    if (!v || !v.data) return @[];
    return [self cosineTopK:k forQuery:v.data excludingID:v.objectID];
}

- (NSArray<ESVectorSearchResult *> *)cosineTopK:(NSUInteger)k
                                       forQuery:(NSData *)queryVectorData
                                    excludingID:(NSManagedObjectID *)excludeID {
    if (!queryVectorData || queryVectorData.length == 0) return @[];
    NSUInteger queryDim = queryVectorData.length / sizeof(float);

    __block NSDictionary *snapshot;
    dispatch_sync(_isolationQueue, ^{
        snapshot = [self.vectorDataDictionary copy];
    });
    if (snapshot.count == 0) return @[];

    const float *queryVec = (const float *)queryVectorData.bytes;
    ESTopKScores *tracker = [[ESTopKScores alloc] initWithCapacity:k];

    [snapshot enumerateKeysAndObjectsUsingBlock:^(NSManagedObjectID *objID, ESVectorCacheEntry *entry, BOOL *stop) {
        if ([objID isEqual:excludeID]) return;
        NSData *blob = entry.vectorData;
        if (blob.length / sizeof(float) != queryDim) return;

        const float *vec = (const float *)blob.bytes;
        float score = 0.0f;
        vDSP_dotpr(queryVec, 1, vec, 1, &score, queryDim);
        // Raw cosine — no decay weighting
        [tracker addScore:score forObjectID:objID];
    }];

    NSArray<NSDictionary *> *topEntries = [tracker topEntries];
    if (topEntries.count == 0) return @[];

    NSMutableArray<NSManagedObjectID *> *topIDs = [NSMutableArray arrayWithCapacity:topEntries.count];
    for (NSDictionary *dict in topEntries) {
        [topIDs addObject:dict[@"objectID"]];
    }

    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *fetchRequest = [CDVector fetchRequest];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"self IN %@", topIDs];
    fetchRequest.relationshipKeyPathsForPrefetching = @[@"memory"];

    NSArray<CDVector *> *topVectors = [context executeFetchRequest:fetchRequest error:nil];
    NSMutableDictionary<NSManagedObjectID *, CDVector *> *vectorMap = [NSMutableDictionary dictionaryWithCapacity:topVectors.count];
    for (CDVector *v in topVectors) {
        vectorMap[v.objectID] = v;
    }

    NSMutableArray<ESVectorSearchResult *> *results = [NSMutableArray arrayWithCapacity:topEntries.count];
    for (NSDictionary *entry in topEntries) {
        NSManagedObjectID *objID = entry[@"objectID"];
        CDVector *vector = vectorMap[objID];
        if (vector && vector.memory) {
            ESVectorSearchResult *result = [ESVectorSearchResult new];
            result.memory = (CDMemory *)vector.memory;
            // cosineTopK: is pure cosine (no decay weighting). The "score"
            // in the entry dict is the raw cosine because addScore: with
            // single-arg defaults cosine == score.
            result.cosine = [entry[@"score"] floatValue];
            result.score = result.cosine;
            [results addObject:result];
        }
    }
    return results;
}

#pragma mark - Visualization

- (NSArray<NSDictionary *> *)curveDataPointsForDecayLevel:(NSString *)decayLevel {
    __block NSDictionary *snapshot;
    dispatch_sync(_isolationQueue, ^{
        snapshot = [self.vectorDataDictionary copy];
    });
    if (snapshot.count == 0) return @[];

    NSDictionary *preset = [[self class] decayPresets][decayLevel ?: [[self class] defaultDecayLevel]];
    float d = [preset[@"d"] floatValue];
    float slope = [preset[@"slope"] floatValue];
    float shift = [preset[@"shift"] floatValue];

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // Max access count for heat normalization
    int64_t maxAccess = 1;
    for (ESVectorCacheEntry *entry in snapshot.allValues) {
        if ((int64_t)entry.accessCount > maxAccess) maxAccess = (int64_t)entry.accessCount;
    }

    NSMutableArray *points = [NSMutableArray arrayWithCapacity:snapshot.count];
    for (ESVectorCacheEntry *entry in snapshot.allValues) {
        float daysSinceAccess;
        if (entry.lastAccessedTimestamp == 0.0) {
            daysSinceAccess = (float)((now - entry.creationTimestamp) / 86400.0);
        } else {
            daysSinceAccess = (float)((now - entry.lastAccessedTimestamp) / 86400.0);
            if (daysSinceAccess < 0.0f) daysSinceAccess = 0.0f;
        }

        float recency = (d == 0.0f) ? 1.0f :
            [self sigmoidRecency:daysSinceAccess rate:d slope:slope shift:shift];
        float heat = (float)entry.accessCount / (float)maxAccess;

        [points addObject:@{
            @"age": @(daysSinceAccess),
            @"score": @(recency),
            @"heat": @(heat)
        }];
    }
    return points;
}

#pragma mark - Statistics

- (NSDictionary *)cacheStatistics {
    __block NSUInteger count = 0;
    __block NSUInteger dim = 0;
    dispatch_sync(_isolationQueue, ^{
        count = self.vectorDataDictionary.count;
        dim = self.dimension;
    });

    double memoryMB = 0.0;
    if (count > 0 && dim > 0) {
        memoryMB = (double)(count * dim * sizeof(float)) / (1024.0 * 1024.0);
    }

    return @{
        @"vectorCount": @(count),
        @"dimension": @(dim),
        @"memoryMB": @(memoryMB),
        @"status": count > 0 ? @"ready" : @"empty"
    };
}

#pragma mark - Bulk Reindex

- (void) deleteAllVectors {
    NSError *fetchError;
    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *vectorFetch = [CDVector fetchRequest];
    NSArray<CDVector *> *vectors = [context executeFetchRequest:vectorFetch error:&fetchError];
    for (CDVector *vector in vectors) {
        [context deleteObject:vector];
    }
    [context save:&fetchError];
}


- (void)recomputeAllVectorsWithCompletion:(void(^)(BOOL success, NSUInteger count, NSError * _Nullable error))completion {
    // Tear down FRC and clear cache before reindex. The FRC delegate can't
    // reliably process hundreds of child-context changes. We'll rewarm the
    // cache from scratch when reindex is done.
    _fetchedResultsController.delegate = nil;
    _fetchedResultsController = nil;
    dispatch_barrier_sync(_isolationQueue, ^{
        [self.vectorDataDictionary removeAllObjects];
        self.dimension = 0;
    });
    ESLog(@"[Reindex] FRC torn down, cache cleared");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        context.parentContext = [ESCoreDataStack shared].viewContext;

        __block NSError *operationError = nil;
        __block NSUInteger processedCount = 0;

        [context performBlockAndWait:^{
            // Delete all vectors through the context (no batch delete — no zombies)
            NSFetchRequest *deleteRequest = [CDVector fetchRequest];
            NSError *deleteError = nil;
            NSArray<CDVector *> *existingVectors = [context executeFetchRequest:deleteRequest error:&deleteError];
            if (deleteError) {
                operationError = deleteError;
                return;
            }
            for (CDVector *vec in existingVectors) {
                [context deleteObject:vec];
            }

            // Fetch all head memories (exclude revisions)
            NSFetchRequest *memoryFetch = [CDMemory fetchRequest];
            memoryFetch.includesSubentities = NO;
            memoryFetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES]];

            NSError *fetchError = nil;
            NSArray<CDMemory *> *memories = [context executeFetchRequest:memoryFetch error:&fetchError];
            if (fetchError) {
                operationError = fetchError;
                return;
            }

            NSUInteger batchSize = 100;
            NSUInteger total = memories.count;

            for (NSUInteger i = 0; i < total; i++) {
                @autoreleasepool {
                    CDMemory *memory = memories[i];

                    // Summary-only input. Memories without a summary are
                    // skipped — they can't participate in vector search
                    // until they're summarized.
                    NSString *embeddingText = memory.summary;
                    if (embeddingText.length > 0) {
                        NSString *memoryLanguage = memory.language.length > 0
                            ? memory.language
                            : @"en";
                        NSData *vectorData = [ESVectorEngine vectorDataFromString:embeddingText
                                                                            title:memory.title
                                                                             task:ESEmbeddingTaskDocument];
                        if (vectorData) {
                            id<ESSummaryEmbedder> embedder = [ESVectorEngine summaryEmbedder];

                            CDVector *newVector = [NSEntityDescription insertNewObjectForEntityForName:@"CDVector"
                                                                               inManagedObjectContext:context];
                            CDEmbedder *embedderEntity = [CDEmbedder findOrCreateWithIdentifier:embedder.identifier
                                                                                       dimension:embedder.vectorDimension
                                                                                       inContext:context];
                            [embedderEntity touchDateLastUsed];
                            newVector.data = vectorData;
                            newVector.dateCreated = [NSDate now];
                            newVector.accessCount = memory.accessCount;
                            newVector.lastAccessed = memory.dateAccessed;
                            newVector.embedderIdentifier = embedder.identifier;
                            newVector.embedder = embedderEntity;
                            newVector.language = memoryLanguage;
                            [memory addVectorsObject:newVector];
                            processedCount++;
                        }
                    }

                    if (i > 0 && (i % batchSize == 0 || i == total - 1)) {
                        NSError *saveError = nil;
                        [context save:&saveError];
                        if (saveError) {
                            operationError = saveError;
                            return;
                        }
                    }
                }
            }

            // Final save
            NSError *finalSaveError = nil;
            [context save:&finalSaveError];
            if (finalSaveError) {
                operationError = finalSaveError;
                return;
            }

            // Push to parent
            dispatch_sync(dispatch_get_main_queue(), ^{
                [context.parentContext save:nil];
            });
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL success = (operationError == nil);
            ESLog(@"ESVectorEngine: recompute %@ (%lu vectors)", success ? @"succeeded" : @"failed", (unsigned long)processedCount);

            // Rewarm: recreate FRC and reload cache from persisted vectors
            ESLog(@"[Reindex] rewarming cache...");
            [self warmCache];
            ESLog(@"[Reindex] cache rewarmed — %lu vectors", (unsigned long)self.vectorDataDictionary.count);

            if (completion) {
                completion(success, processedCount, operationError);
            }
        });
    });
}

#pragma mark - Startup Integrity

- (void)backfillMissingVectorsWithCompletion:(void(^)(NSUInteger backfilledCount))completion {
    // Find memories without a CDVector for the currently active summary
    // embedder. Covers the empty-archive case and any memory whose
    // existing vectors are stale (left behind by a previous embedder).
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    id<ESSummaryEmbedder> active = self.summaryEmbedder;
    if (!active) {
        ESLog(@"ESVectorEngine: backfill skipped — no summary embedder registered");
        if (completion) completion(0);
        return;
    }
    NSString *activeID = active.identifier;

    NSFetchRequest *fetch = [CDMemory fetchRequest];
    fetch.includesSubentities = NO;
    // Match on the vector's embedderIdentifier STRING, not through the
    // embedder relationship. CloudKit replay can duplicate CDEmbedder rows
    // and reshuffle relationships (July 5 2026: two rows shared the active
    // identifier and a relationship-based orphan test re-embedded the whole
    // archive on launch). The string is stamped on the vector itself, so
    // this predicate agrees with archive_maintenance's activeVectorCount and
    // is immune to embedder-row chaos.
    // The summary clause mirrors archive_maintenance's missing-count: a
    // memory with no summary cannot be embedded (enqueue skips it), so
    // fetching it here just re-reports the same "orphans" every launch.
    fetch.predicate = [NSPredicate predicateWithFormat:
                       @"(SUBQUERY(vectors, $v, $v.embedderIdentifier == %@).@count == 0) AND "
                       @"(summary != nil AND summary != %@)",
                       activeID, @""];

    NSError *fetchError = nil;
    NSArray<CDMemory *> *orphans = [ctx executeFetchRequest:fetch error:&fetchError];
    if (fetchError) {
        NSLog(@"ESVectorEngine: backfill fetch failed: %@", fetchError);
        if (completion) completion(0);
        return;
    }
    if (orphans.count == 0) {
        if (completion) completion(0);
        return;
    }

    NSUInteger count = orphans.count;
    ESLog(@"ESVectorEngine: found %lu memories without a vector for %@ — enqueueing...",
          (unsigned long)count, activeID);

    for (CDMemory *memory in orphans) {
        [self enqueueVectorForMemory:memory];
    }

    // Fire completion after all enqueued work finishes. The trailing op is
    // a completion fence — it carries no real vector work, only sequences
    // the callback after the prior N ops drain through the serial queue.
    // Tracked in _pendingFenceOps so `pendingVectorOperations` reports
    // real-work depth (see getter for rationale).
    if (completion) {
        atomic_fetch_add_explicit(&_pendingFenceOps, 1, memory_order_relaxed);
        [self.vectorQueue addOperationWithBlock:^{
            atomic_fetch_sub_explicit(&self->_pendingFenceOps, 1, memory_order_relaxed);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(count);
            });
        }];
    }
}

#pragma mark - Maintenance surface

- (NSString *)pendingEmbedderIdentifier {
    if (self.pendingVectorOperations == 0) return nil;
    return self.summaryEmbedder.identifier;
}

- (NSDictionary *)staleVectorReport {
    NSString *activeID = self.summaryEmbedder.identifier;

    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[@"embedderIdentifier"];
    req.returnsDistinctResults = NO;

    NSError *err = nil;
    NSArray<NSDictionary *> *rows = [ctx executeFetchRequest:req error:&err];
    if (err) {
        NSLog(@"ESVectorEngine: stale scan fetch failed: %@", err);
        return @{ @"count": @0, @"embedderIDs": @[] };
    }

    NSCountedSet *staleCounts = [NSCountedSet new];
    for (NSDictionary *row in rows) {
        NSString *id_ = row[@"embedderIdentifier"];
        if (id_.length == 0) {
            [staleCounts addObject:@""];
        } else if (![id_ isEqualToString:activeID]) {
            [staleCounts addObject:id_];
        }
    }

    NSUInteger total = 0;
    for (NSString *id_ in staleCounts) total += [staleCounts countForObject:id_];

    return @{
        @"count":       @(total),
        @"embedderIDs": [staleCounts.allObjects sortedArrayUsingSelector:@selector(compare:)],
    };
}

- (NSUInteger)eraseVectorsForActiveEmbedder {
    NSString *activeID = self.summaryEmbedder.identifier;
    if (activeID.length == 0) return 0;

    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
    req.predicate = [NSPredicate predicateWithFormat:@"embedderIdentifier == %@", activeID];

    NSError *err = nil;
    NSArray<NSManagedObject *> *vectors = [ctx executeFetchRequest:req error:&err];
    if (err) {
        NSLog(@"ESVectorEngine: erase fetch failed: %@", err);
        return 0;
    }
    NSUInteger count = vectors.count;
    for (NSManagedObject *v in vectors) [ctx deleteObject:v];
    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        NSLog(@"ESVectorEngine: erase save failed: %@", saveErr);
        return 0;
    }
    [self reloadVectorCache];
    ESLog(@"ESVectorEngine: erased %lu vectors for %@", (unsigned long)count, activeID);
    return count;
}

- (NSDictionary *)cleanArchive {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    // --- 1. Stale vectors (not produced by the active summary embedder) ---
    NSDictionary *staleReport = [self staleVectorReport];
    NSArray<NSString *> *staleIDs = staleReport[@"embedderIDs"] ?: @[];
    NSUInteger orphRemoved = 0;

    for (NSString *id_ in staleIDs) {
        NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
        if (id_.length == 0) {
            req.predicate = [NSPredicate predicateWithFormat:@"embedderIdentifier == nil"];
        } else {
            req.predicate = [NSPredicate predicateWithFormat:@"embedderIdentifier == %@", id_];
        }
        NSError *fetchErr = nil;
        NSArray<NSManagedObject *> *rows = [ctx executeFetchRequest:req error:&fetchErr];
        if (fetchErr) {
            NSLog(@"ESVectorEngine: clean stale fetch (%@) failed: %@", id_, fetchErr);
            continue;
        }
        for (NSManagedObject *v in rows) [ctx deleteObject:v];
        orphRemoved += rows.count;
    }

    // Cascade-delete CDEmbedder inventory rows for stale identifiers.
    if (staleIDs.count > 0) {
        NSFetchRequest *embReq = [NSFetchRequest fetchRequestWithEntityName:@"CDEmbedder"];
        embReq.predicate = [NSPredicate predicateWithFormat:@"identifier IN %@",
                            [staleIDs filteredArrayUsingPredicate:
                             [NSPredicate predicateWithFormat:@"length > 0"]]];
        NSArray<NSManagedObject *> *embs = [ctx executeFetchRequest:embReq error:nil];
        for (NSManagedObject *e in embs) [ctx deleteObject:e];
    }

    // --- 2. Empty memories ---
    NSFetchRequest *emptyReq = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    emptyReq.includesSubentities = NO;  // exclude CDMemoryRevision
    emptyReq.predicate = [NSPredicate predicateWithFormat:
        @"(body == nil OR body == %@) AND (summary == nil OR summary == %@) AND (locked == NO OR locked == nil)",
        @"", @""];

    NSError *emptyErr = nil;
    NSArray<NSManagedObject *> *empties = [ctx executeFetchRequest:emptyReq error:&emptyErr];
    if (emptyErr) {
        NSLog(@"ESVectorEngine: clean empty-memory fetch failed: %@", emptyErr);
        empties = @[];
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:MIN(empties.count, 50u)];
    for (NSManagedObject *m in empties) {
        if (titles.count >= 50) break;
        NSString *t = [m valueForKey:@"title"];
        [titles addObject:(t.length > 0 ? t : @"(untitled)")];
    }
    NSUInteger emptyRemoved = empties.count;
    for (NSManagedObject *m in empties) [ctx deleteObject:m];

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        NSLog(@"ESVectorEngine: clean save failed: %@", saveErr);
    }

    // Drop empty-string entries from the stale-ID list before reporting.
    NSArray<NSString *> *reportedIDs = [staleIDs filteredArrayUsingPredicate:
                                        [NSPredicate predicateWithFormat:@"length > 0"]];

    return @{
        @"staleVectorsRemoved": @(orphRemoved),
        @"staleEmbedderIDs":    reportedIDs,
        @"emptyMemoriesRemoved": @(emptyRemoved),
        @"emptyMemoryTitles":    [titles copy],
    };
}

@end
