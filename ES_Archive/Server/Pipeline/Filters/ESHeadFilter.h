//
//  ESHeadFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  head — first N from the prior population. Pure slice, no server call.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESHeadFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
