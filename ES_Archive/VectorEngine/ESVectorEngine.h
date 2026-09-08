//
//  ESVectorEngine.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Vector embedding generation, in-memory cache, and semantic search
//  for the memory-summary corpus. Backed by the active summary
//  embedder (id<ESSummaryEmbedder>), resolved at init from the
//  current device locale.
//
//  The engine is architected for a second slot — id<ESEmbedder>
//  for the full-text corpus — but only the summary slot is wired
//  for the initial release. See ESSummaryEmbedder.h / ESEmbedder.h.
//

#import <Foundation/Foundation.h>
#import "ESSummaryEmbedder.h"   // id<ESSummaryEmbedder>, ESEmbeddingTask

@class CDMemory, ESVectorSearchResult, NSManagedObjectID, ESVectorCacheEntry;

NS_ASSUME_NONNULL_BEGIN

@interface ESVectorEngine : NSObject

+ (instancetype)shared;

#pragma mark - Embedding Generation

/// Encode a string under the active summary embedder. Returns unit-
/// length float32 NSData of length `vectorDimension * sizeof(float)`.
/// Both ingestion and query use these so resulting vectors live in the
/// same space and cosines between them are directly comparable.
///
/// `vectorDataFromString:` embeds `text` as a stored document (memory
/// summary). The `task:` variant selects the retrieval role so asymmetric
/// models (e.g. EmbeddingGemma) apply the correct query/document prefix. The
/// `title:task:` variant additionally folds a document title into the prompt
/// (`title: <title> | text: <text>`) — measurably better retrieval; pass the
/// memory's title for documents, nil for queries.
+ (nullable NSData *)vectorDataFromString:(NSString *)text;
+ (nullable NSData *)vectorDataFromString:(NSString *)text task:(ESEmbeddingTask)task;
+ (nullable NSData *)vectorDataFromString:(NSString *)text
                                    title:(nullable NSString *)title
                                     task:(ESEmbeddingTask)task;

#pragma mark - Vector Queue

/// Enqueue vector generation for a memory. Runs on a serial background
/// queue. Safe to call from any thread. Deletes any existing CDVector
/// rows for the memory, generates a new one from `memory.summary`, saves.
- (void)enqueueVectorForMemory:(CDMemory *)memory;

/// Number of operations pending in the vector queue (including running).
@property (nonatomic, readonly) NSUInteger pendingVectorOperations;

/// Posted on the main queue once the initial vector cache is fully
/// loaded at startup. userInfo: @{ @"count": NSNumber (vector count) }
extern NSNotificationName const ESVectorCacheReadyNotification;

#pragma mark - Cache Management

- (void)warmCache;

/// Immutable copy of the retrieval cache (vector objectID -> entry), taken
/// under the isolation queue. Safe to hand to any thread; entries are
/// immutable value holders. For bulk consumers (the Archive Scope build)
/// that would otherwise re-copy the cache once per query.
- (NSDictionary<NSManagedObjectID *, ESVectorCacheEntry *> *)cacheSnapshot;

/// Dimension of the vectors in the cache (0 while empty). Thread-safe.
- (NSUInteger)cacheDimension;

#pragma mark - Embedder

/// The active summary embedder — a single universal model (multilingual
/// EmbeddingGemma), resolved at init via ESSummaryEmbedderForCurrentLocale()
/// and fixed for the session. Returns nil only when no summary embedder is
/// registered — callers must refuse semantic operations rather than
/// fabricate a result.
+ (nullable id<ESSummaryEmbedder>)summaryEmbedder;

#pragma mark - Scoring

/// Ordered focus presets: @[@"day", @"week", @"month", @"none"].
+ (NSArray<NSString *> *)decayLevels;

/// Maps level name → sigmoid parameters { d, slope, shift }.
+ (NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *)decayPresets;

/// Maps level name → short poetic description assembled from preset values.
+ (NSDictionary<NSString *, NSString *> *)decayLevelDescriptions;

/// Default decay level used when a caller passes nil / no `focus` argument.
+ (NSString *)defaultDecayLevel;

#pragma mark - Access Tracking Push

/// Push CDMemory access stats to CDVector entity and cache entry.
/// Call after CDMemory.recordAccess + saveContext. Thread-safe.
- (void)pushAccessStatsForMemory:(CDMemory *)memory;

#pragma mark - Search

- (NSArray<ESVectorSearchResult *> *)topK:(NSUInteger)k forQuery:(NSData *)queryVector;
- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query limit:(NSUInteger)k;

/// Semantic search with per-call focus override. nil = use global setting.
- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query
                                               limit:(NSUInteger)k
                                          decayLevel:(nullable NSString *)decayLevel;

/// Semantic search restricted to an explicit set of CDVector objectIDs.
- (NSArray<ESVectorSearchResult *> *)searchWithQuery:(NSString *)query
                                               limit:(NSUInteger)k
                                          decayLevel:(nullable NSString *)decayLevel
                                    allowedVectorIDs:(nullable NSSet<NSManagedObjectID *> *)allowed;

- (NSArray<ESVectorSearchResult *> *)similarToMemory:(CDMemory *)memory limit:(NSUInteger)k;

/// Similarity restricted to an explicit set of CDVector objectIDs — used to
/// scope the "similar" flare to the connecting persona's own memories.
- (NSArray<ESVectorSearchResult *> *)similarToMemory:(CDMemory *)memory
                                               limit:(NSUInteger)k
                                    allowedVectorIDs:(nullable NSSet<NSManagedObjectID *> *)allowed;

/// Pure cosine similarity (no decay weighting). For graph topology.
- (NSArray<ESVectorSearchResult *> *)cosineSimilarToMemory:(CDMemory *)memory limit:(NSUInteger)k;

/// Return top-K memories similar to the given vector. Excludes any
/// memory whose title matches excludedTitle (case-insensitive).
/// Returns NSArray of NSDictionary: @{ @"title": NSString, @"score": NSNumber (float) }
- (NSArray<NSDictionary *> *)topKSimilarToVector:(NSData *)vector
                                           limit:(NSInteger)limit
                                  excludingTitle:(NSString *)excludedTitle;

/// As above, restricted to an explicit set of CDVector objectIDs — used to
/// scope the store-time similarity flare to the connecting persona.
- (NSArray<NSDictionary *> *)topKSimilarToVector:(NSData *)vector
                                           limit:(NSInteger)limit
                                  excludingTitle:(NSString *)excludedTitle
                                allowedVectorIDs:(nullable NSSet<NSManagedObjectID *> *)allowed;

#pragma mark - Visualization

- (NSArray<NSDictionary *> *)curveDataPointsForDecayLevel:(NSString *)decayLevel;

#pragma mark - Statistics

- (NSDictionary *)cacheStatistics;

#pragma mark - Bulk Reindex

/// Delete every CDVector row, then re-encode `memory.summary` for every
/// CDMemory under the active embedder. Called by archive_maintenance(reindexSummaries).
- (void)recomputeAllVectorsWithCompletion:(void(^)(BOOL success, NSUInteger count, NSError * _Nullable error))completion;

#pragma mark - Startup Integrity

/// Find memories with no vector under the active summary embedder and
/// generate one from their summary.
- (void)backfillMissingVectorsWithCompletion:(void(^)(NSUInteger backfilledCount))completion;

#pragma mark - Maintenance surface

/// Identifier of the embedder that owns the currently-pending vector
/// ops. Returns nil when `pendingVectorOperations == 0`.
- (nullable NSString *)pendingEmbedderIdentifier;

/// CDVector rows whose embedderIdentifier doesn't match the active
/// summary embedder — i.e. left behind by a previous model. Two keys:
///   - "count":       NSNumber<NSUInteger> — total stale rows
///   - "embedderIDs": NSArray<NSString *>  — distinct stale identifiers
/// Diagnostic only. Since the archive moved to a single universal embedder
/// (EmbeddingGemma), a non-active vector has no purpose — there is no
/// multi-embedder fallback to preserve — so the launch heal
/// (ESDeduplicator) now purges these automatically. This report just
/// surfaces the count between heals.
- (NSDictionary *)staleVectorReport;

/// Synchronously delete every CDVector belonging to the active embedder.
/// Returns the deleted count.
- (NSUInteger)eraseVectorsForActiveEmbedder;

/// Synchronously remove dead weight from the archive in one pass:
///   1. Stale CDVectors (embedderIdentifier doesn't match active).
///   2. Empty CDMemory rows (no body AND no summary, skipping locked).
- (NSDictionary *)cleanArchive;

@end

NS_ASSUME_NONNULL_END
