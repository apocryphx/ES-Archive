//
//  ESW2vgrepFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  w2vgrep — semantic similarity search via NLContextualEmbedding cosine.
//  Non-fusable: ranking happens in the vector engine, not via Core Data
//  predicate, so this filter implements applyToInput: directly. When piped
//  from a prior filter, ranks within that population.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESW2vgrepFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
