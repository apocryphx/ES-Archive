//
//  EmbeddingGemmaEmbedder.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  The sole summary embedder (replaced bge-small-en, July 2026): Google
//  EmbeddingGemma-300M, QAT-q4_0 source, converted to a 512-token / 768-dim
//  Core ML bundle with int4 blockwise weights (~188 MB). Multilingual —
//  100+ languages, English-parity with the retired BGE model.
//
//  Unlike the BGE wrapper, the Core ML graph performs mean-pooling, both
//  Dense projections, and L2-normalisation internally, so the graph emits a
//  finished unit-length 768-vector. This class therefore only: applies the
//  retrieval task prefix, tokenises (Gemma BPE via ObjCTokenizer), runs the
//  model (inputs `input_ids` + `attention_mask`, no token_type_ids), and
//  copies out the `embedding` output.
//
//  Task prefixes (EmbeddingGemma retrieval convention — asymmetric):
//    query    → "task: search result | query: <query text>"
//    document → "title: <memory title|none> | text: <summary>"
//  Documents fold in the memory's real title. The embedded text is the
//  summary, which does NOT contain the title, so the title is additive:
//  measured +9 pts cross-lingual top-1 (Japanese +13) vs title:none.
//  Falls back to "none" when a memory has no title.
//
//  Compute: fp32 (Gemma activations overflow fp16), CPU+GPU — the ANE cannot
//  run fp32, and int4 weights keep the bundle small regardless of compute
//  precision.
//

#import <Foundation/Foundation.h>
#import "ESSummaryEmbedder.h"

NS_ASSUME_NONNULL_BEGIN

/// CDVector.embedderID value for this model. Changing the wrapped model or its
/// quantisation MUST change this string so the engine reindexes stale vectors.
FOUNDATION_EXPORT NSString *const EmbeddingGemmaEmbedderIdentifier;

@interface EmbeddingGemmaEmbedder : NSObject <ESSummaryEmbedder>

/// Designated initialiser. `modelURL` is a compiled `.mlmodelc` (Xcode build
/// output) or a raw `.mlpackage` (compiled on-demand). `tokenizerJSONURL` is
/// EmbeddingGemma's HuggingFace `tokenizer.json` (BPE).
- (nullable instancetype)initWithModelURL:(NSURL *)modelURL
                         tokenizerJSONURL:(NSURL *)tokenizerJSONURL
                                maxLength:(NSInteger)maxLength
                                    error:(NSError * _Nullable * _Nullable)error;

/// Zero-arg factory used by the discovery layer. Loads the bundled
/// `EmbeddingGemmaEncoder.{mlmodelc,mlpackage}` + `embeddinggemma.tokenizer.json`.
/// Returns nil (logging) if assets are missing.
+ (nullable instancetype)defaultEmbedder;

@end

NS_ASSUME_NONNULL_END
