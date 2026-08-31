//
//  ESCatFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  cat — read full memory bodies. Terminal stage: produces a response
//  shape with full memory dicts (title, body, summary, dates, etc.)
//  rather than threading a population to a successor.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESCatFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
