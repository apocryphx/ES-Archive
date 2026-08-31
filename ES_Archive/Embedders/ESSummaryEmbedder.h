//
//  ESSummaryEmbedder.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Protocol for the memory-summary embedder slot of the vector engine.
//
//  The summary embedder operates on a single corpus: each memory's
//  Claude-generated English-prose `summary`. Summaries are short (~100
//  words), curated, and always in one language; a small bundled model
//  is optimal — fast, no download, no availability surface.
//
//  This protocol is intentionally narrower than ESEmbedder (the future
//  full-text contract). One language per instance. No language hint on
//  encode. No download flow. No defaultLanguage setter. The discovery
//  layer routes to the right embedder by inspecting `language` against
//  the current device locale.
//
//  Drop-in discipline:
//    - Conform to ESSummaryEmbedder.
//    - Provide a zero-arg factory: +defaultEmbedder, +sharedEmbedder, or
//      +new (probed in that order). Return nil if assets are missing.
//    - Add the .m + model assets to the target's bundle resources.
//      That is the entire integration gesture; the runtime walk in
//      ESSummaryEmbedderAvailableClasses() picks up the class.
//
//  Identifier rule:
//    Must change when the wrapped model changes. CDVector.embedderID is
//    keyed on this; the engine compares against the active embedder at
//    startup to detect stale vectors.
//
//  Threading:
//    Every conformer must be safe to call from multiple threads after
//    init. Core ML-backed implementations should route `predictionFrom-
//    Features:` through a per-instance serial queue via dispatch_sync,
//    which propagates the caller's QoS to the worker. See
//    EmbeddingGemmaEmbedder for the reference implementation.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the text being embedded represents. Retrieval-asymmetric models embed a
/// stored document differently from a live query (distinct task prefixes);
/// symmetric models treat both identically and may ignore this.
typedef NS_ENUM(NSInteger, ESEmbeddingTask) {
    ESEmbeddingTaskDocument = 0,  ///< A stored memory summary being indexed.
    ESEmbeddingTaskQuery    = 1,  ///< A live search query.
};

@protocol ESSummaryEmbedder <NSObject>
@required

#pragma mark - Identity

/// Stable identifier encoding model + version. Example:
/// `@"google/embeddinggemma-300m-qat-q4_0-768"`. CDVector.embedderID is
/// keyed on this. MUST change when the wrapped model changes.
@property (nonatomic, readonly, copy) NSString *identifier;

/// Output vector dimension. The engine sizes caches and SIMD loops on
/// this value.
@property (nonatomic, readonly) NSUInteger vectorDimension;

/// Maximum input sequence length the underlying model can process.
/// Inputs longer than this are truncated by the embedder; callers do
/// not enforce.
@property (nonatomic, readonly) NSUInteger maximumSequenceLength;

#pragma mark - Language

/// BCP 47 root tag — `@"en"`, `@"zh"`. No region subtag. Used for
/// prefix matching against `[NSLocale preferredLanguages]` when the
/// engine resolves the active embedder for the current locale.
@property (nonatomic, readonly, copy) NSString *language;

#pragma mark - Encoding

/// Encode `text` into a unit-length float32 NSData of length
/// `vectorDimension * sizeof(float)`. `task` distinguishes a stored memory
/// (document) from a live search query — asymmetric models (e.g. EmbeddingGemma
/// with retrieval task prefixes) embed the two differently; symmetric models may
/// ignore it. `title` is the document's title (the memory's title field), folded
/// into the document prompt for models with a title slot; pass nil for queries or
/// when there is no title. Returns nil with errOut populated on failure (model
/// not loaded, internal Core ML error, etc.).
- (nullable NSData *)encodeString:(NSString *)text
                            title:(nullable NSString *)title
                             task:(ESEmbeddingTask)task
                            error:(NSError * _Nullable * _Nullable)errOut;

#pragma mark - Calibration

/// Empirical score-band reference values. Keys:
///   verbatimMin, paraphraseMin, sameConceptMin, broadlyRelatedMin,
///   noiseFloor. Provisional defaults ship with each embedder class;
///   updated after T1 measurement on the live archive.
- (NSDictionary<NSString *, NSNumber *> *)scoreBandCalibration;

@optional

#pragma mark - Selection priority

/// Tiebreaker among conformers with the same `language`. Higher wins.
/// Default 0 when unimplemented. The bundled English embedder ships
/// with priority 100.
+ (NSInteger)priority;

@end


#pragma mark - Discovery

/// Walk the Obj-C runtime once at startup and return every class that
/// conforms to ESSummaryEmbedder. Cached for the process lifetime.
FOUNDATION_EXPORT NSArray<Class> *ESSummaryEmbedderAvailableClasses(void);

/// Instantiate every available class via +defaultEmbedder /
/// +sharedEmbedder / +new (probed in that order). Returns only
/// instances that initialised successfully. Cached for the process
/// lifetime — embedder classes are linked at compile time.
FOUNDATION_EXPORT NSArray<id<ESSummaryEmbedder>> *ESSummaryEmbedderActiveInstances(void);

/// Resolve the best embedder for the current device locale:
///   1. Read the root tag of `[NSLocale preferredLanguages].firstObject`
///      (`@"zh-Hans-CN"` → `@"zh"`, `@"en-US"` → `@"en"`).
///   2. Walk active instances sorted by priority descending. Return
///      the first whose `language` matches.
///   3. No match: return the highest-priority instance whose
///      `language` is `@"en"`.
///   4. Returns nil only if no active instances exist — indicates a
///      misconfigured bundle.
FOUNDATION_EXPORT id<ESSummaryEmbedder> _Nullable ESSummaryEmbedderForCurrentLocale(void);

NS_ASSUME_NONNULL_END
