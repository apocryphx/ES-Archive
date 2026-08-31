//
//  ESTailFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  tail — last N from the prior population. Mirror of head, slices from
//  the end.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESTailFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
