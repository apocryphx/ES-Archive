//
//  ESDiscoverFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  discover — structural lenses on the archive (popular, forgotten, lost,
//  hubs, revised, discussed, hot).
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESDiscoverFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
