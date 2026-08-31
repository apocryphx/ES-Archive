//
//  EmbeddingGemmaEmbedder.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "EmbeddingGemmaEmbedder.h"
@import ObjCTokenizer;
@import CoreML;
@import Accelerate;

// "-titled" marks the document-prompt config that folds in the memory title.
// It differs from the earlier title:none vectors, so the suffix change flags
// those as stale and prompts a reindex.
NSString *const EmbeddingGemmaEmbedderIdentifier = @"google/embeddinggemma-300m-qat-q4_0-768-titled";

// EmbeddingGemma retrieval task prefix for queries (from the model card).
// The document prompt is built per-call: "title: <title|none> | text: <text>".
static NSString *const kEGQueryPrefix = @"task: search result | query: ";

@interface EmbeddingGemmaEmbedder () {
    NSInteger _maxLen;
    dispatch_queue_t _predictionQueue;
    NSString *_outputName;   // single embedding output, read from the model
}
@property (nonatomic, strong, readwrite) OCTTokenizer *tokenizer;
@property (nonatomic, strong, readwrite) MLModel      *model;
@end

@implementation EmbeddingGemmaEmbedder

#pragma mark - Init

- (instancetype)initWithModelURL:(NSURL *)modelURL
                tokenizerJSONURL:(NSURL *)tokenizerJSONURL
                       maxLength:(NSInteger)maxLength
                           error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _maxLen = maxLength;
    _predictionQueue = dispatch_queue_create("com.esarchive.embgemma.prediction", DISPATCH_QUEUE_SERIAL);

    OCTTokenizer *t = [OCTTokenizer tokenizerWithJSONFileURL:tokenizerJSONURL error:error];
    if (!t) return nil;
    _tokenizer = t;

    // Raw .mlpackage → compile to .mlmodelc; already-.mlmodelc (Xcode
    // pre-compiled at build time, the common case) is used as-is.
    NSURL *compiled = modelURL;
    if (![modelURL.pathExtension isEqualToString:@"mlmodelc"]) {
        compiled = [MLModel compileModelAtURL:modelURL error:error];
        if (!compiled) return nil;
    }

    MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
    // fp32 compute: Gemma's activation ranges overflow fp16 (→ NaN). The ANE
    // is fp16-only so it is unusable here; GPU runs fp32 fine and is fast for
    // a 300M model. int4 blockwise weights fix the on-disk size (~188 MB)
    // independently of compute precision.
    cfg.computeUnits = MLComputeUnitsCPUAndGPU;

    MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:error];
    if (!m) return nil;
    _model = m;

    // Single output feature (named `sentence_embedding` at conversion; read
    // dynamically so the wrapper doesn't hard-depend on the exact name).
    _outputName = m.modelDescription.outputDescriptionsByName.allKeys.firstObject;
    if (!_outputName) {
        if (error) *error = [NSError errorWithDomain:@"EmbeddingGemmaEmbedder" code:10
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                       @"model exposes no output feature"}];
        return nil;
    }

    return self;
}

+ (instancetype)defaultEmbedder {
    NSBundle *b = [NSBundle mainBundle];
    NSURL *modelURL = [b URLForResource:@"EmbeddingGemmaEncoder" withExtension:@"mlmodelc"];
    if (!modelURL) modelURL = [b URLForResource:@"EmbeddingGemmaEncoder" withExtension:@"mlpackage"];
    NSURL *tokenizerJSONURL = [b URLForResource:@"embeddinggemma.tokenizer" withExtension:@"json"];
    if (!modelURL || !tokenizerJSONURL) {
        NSLog(@"EmbeddingGemmaEmbedder: missing embeddinggemma.tokenizer.json or "
              @"EmbeddingGemmaEncoder.{mlmodelc,mlpackage} in bundle");
        return nil;
    }
    NSError *err = nil;
    EmbeddingGemmaEmbedder *e = [[self alloc] initWithModelURL:modelURL
                                             tokenizerJSONURL:tokenizerJSONURL
                                                    maxLength:512
                                                        error:&err];
    if (!e) NSLog(@"EmbeddingGemmaEmbedder: init failed: %@", err);
    return e;
}

#pragma mark - Helpers

- (MLMultiArray *)_int32ArrayFromNumbers:(NSArray<NSNumber *> *)nums
                                   error:(NSError **)error {
    MLMultiArray *m = [[MLMultiArray alloc] initWithShape:@[ @1, @(_maxLen) ]
                                                  dataType:MLMultiArrayDataTypeInt32
                                                     error:error];
    if (!m) return nil;
    int32_t *p = (int32_t *)m.dataPointer;
    NSUInteger n = MIN(nums.count, (NSUInteger)_maxLen);
    for (NSUInteger i = 0; i < n; i++) p[i] = (int32_t)nums[i].integerValue;
    for (NSUInteger i = n; i < (NSUInteger)_maxLen; i++) p[i] = 0;
    return m;
}

/// Read a (1, D) Core ML output into a unit-length float32 NSData. The graph
/// already L2-normalises; the renormalise here only absorbs fp rounding.
- (NSData *)_vectorFromOutput:(MLMultiArray *)arr {
    NSUInteger D = arr.count;
    if (D == 0) return nil;
    NSInteger s = arr.strides.lastObject.integerValue;   // innermost stride
    float *v = (float *)malloc(D * sizeof(float));

    switch (arr.dataType) {
        case MLMultiArrayDataTypeFloat32: {
            const float *base = (const float *)arr.dataPointer;
            for (NSUInteger i = 0; i < D; i++) v[i] = base[i * s];
            break;
        }
        case MLMultiArrayDataTypeFloat16: {
            const __fp16 *base = (const __fp16 *)arr.dataPointer;
            for (NSUInteger i = 0; i < D; i++) v[i] = (float)base[i * s];
            break;
        }
        case MLMultiArrayDataTypeDouble: {
            const double *base = (const double *)arr.dataPointer;
            for (NSUInteger i = 0; i < D; i++) v[i] = (float)base[i * s];
            break;
        }
        default:
            free(v);
            return nil;
    }

    float ssq = 0.0f;
    vDSP_svesq(v, 1, &ssq, D);
    if (ssq > 0.0f) {
        float scale = 1.0f / sqrtf(ssq);
        vDSP_vsmul(v, 1, &scale, v, 1, D);
    }
    NSData *out = [NSData dataWithBytes:v length:D * sizeof(float)];
    free(v);
    return out;
}

#pragma mark - ESSummaryEmbedder protocol

- (NSString *)identifier { return EmbeddingGemmaEmbedderIdentifier; }
- (NSUInteger)vectorDimension { return 768; }
- (NSUInteger)maximumSequenceLength { return (NSUInteger)_maxLen; }

// Sole embedder. Reports "en" so the locale-routing discovery always resolves
// to it — either by direct match, or (for any other locale) as the English
// fallback. The model itself is multilingual and handles every language.
- (NSString *)language { return @"en"; }

- (NSData *)encodeString:(NSString *)text
                   title:(NSString *)title
                    task:(ESEmbeddingTask)task
                   error:(NSError **)errOut {
    if (text.length == 0) {
        if (errOut) *errOut = [NSError errorWithDomain:@"EmbeddingGemmaEmbedder" code:11
                                              userInfo:@{NSLocalizedDescriptionKey: @"empty input"}];
        return nil;
    }

    // Query: `task: search result | query: <text>` (no title slot).
    // Document: `title: <title|none> | text: <text>` — the real title lifts
    // cross-lingual retrieval because the summary itself doesn't contain it.
    NSString *prefixed;
    if (task == ESEmbeddingTaskQuery) {
        prefixed = [kEGQueryPrefix stringByAppendingString:text];
    } else {
        NSString *t = (title.length > 0) ? title : @"none";
        prefixed = [NSString stringWithFormat:@"title: %@ | text: %@", t, text];
    }

    OCTEncodeOptions *opt = [OCTEncodeOptions new];
    opt.maxLength = _maxLen;
    opt.padding = OCTPaddingMaxLength;
    opt.truncation = OCTTruncationLongest;
    opt.addSpecialTokens = YES;   // Gemma post-processor prepends <bos>

    NSError *err = nil;
    OCTEncoding *enc = [_tokenizer encodeAsEncoding:prefixed options:opt error:&err];
    if (!enc) { if (errOut) *errOut = err; return nil; }

    MLMultiArray *idsM = [self _int32ArrayFromNumbers:enc.ids error:&err];
    if (!idsM) { if (errOut) *errOut = err; return nil; }
    MLMultiArray *maskM = [self _int32ArrayFromNumbers:enc.attentionMask error:&err];
    if (!maskM) { if (errOut) *errOut = err; return nil; }

    MLDictionaryFeatureProvider *inp =
        [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"input_ids": idsM,
                                                                   @"attention_mask": maskM }
                                                          error:&err];
    if (!inp) { if (errOut) *errOut = err; return nil; }

    // Serialise prediction on a dedicated queue; dispatch_sync propagates the
    // caller's QoS so a user-interactive caller isn't left waiting on a
    // lower-priority thread. (Same discipline as the retired BGE wrapper.)
    __block id<MLFeatureProvider> out = nil;
    __block NSError *predErr = nil;
    dispatch_sync(_predictionQueue, ^{
        out = [self->_model predictionFromFeatures:inp error:&predErr];
    });
    if (!out) { if (errOut) *errOut = predErr; return nil; }

    MLMultiArray *emb = [out featureValueForName:_outputName].multiArrayValue;
    if (!emb) {
        if (errOut) *errOut = [NSError errorWithDomain:@"EmbeddingGemmaEmbedder" code:12
                                              userInfo:@{NSLocalizedDescriptionKey:
                                                         @"model embedding output missing"}];
        return nil;
    }
    NSData *vec = [self _vectorFromOutput:emb];
    if (!vec && errOut) {
        *errOut = [NSError errorWithDomain:@"EmbeddingGemmaEmbedder" code:13
                                  userInfo:@{NSLocalizedDescriptionKey: @"vector read produced nil"}];
    }
    return vec;
}

- (NSDictionary<NSString *, NSNumber *> *)scoreBandCalibration {
    // Bands for EmbeddingGemma-300M (768-d, raw cosine, query→document retrieval).
    // Measured on the live archive + the shipped int4 model: identical text
    // ~0.83–0.92 (query and document prefixes differ, so a verbatim match sits
    // below 1.0), strong cross-lingual concept matches ~0.53, unrelated text
    // ~0.05–0.10. The scale is far wider than BGE's, whose noise floor sat ~0.6.
    return @{
        @"verbatimMin":       @0.83,
        @"paraphraseMin":     @0.60,
        @"sameConceptMin":    @0.48,
        @"broadlyRelatedMin": @0.35,
        @"noiseFloor":        @0.15,
    };
}

#pragma mark - Selection priority

+ (NSInteger)priority { return 100; }

@end
