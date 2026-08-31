//
//  ESUntagPipelineFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  untag — pipeline write filter. Detaches a named tag from every memory
//  in the input population. Tag must exist (we error rather than silently
//  no-op so typos don't pass). The detach itself is silent — memories that
//  weren't carrying the tag are unaffected.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESUntagPipelineFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
