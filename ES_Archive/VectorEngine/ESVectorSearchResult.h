//
//  ESVectorSearchResult.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Result object from vector similarity search.
//

#import <Foundation/Foundation.h>

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

@interface ESVectorSearchResult : NSObject

@property (nonatomic, strong) CDMemory *memory;
@property (nonatomic) float score;     // Rescaled 0.0–1.0 (per-query, presentation)
@property (nonatomic) float rawScore;  // Decayed cosine (used for ranking)
@property (nonatomic) float cosine;    // Pre-decay cosine (absolute similarity, [-1, 1])

@end

NS_ASSUME_NONNULL_END
