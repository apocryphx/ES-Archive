//
//  ESLfindFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  lfind — filter memories by metadata (tag, days). Phase 1: fusable filter
//  whose applyToInput: does a Core Data fetch directly. Phase 2 will add
//  predicate/sort/limit contributions for fusion with downstream stages.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESLfindFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
