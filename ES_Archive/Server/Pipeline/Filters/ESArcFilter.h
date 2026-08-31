//
//  ESArcFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  arc — return the temporal session-cluster around an anchor memory.
//
//  Sessions in this archive lay down their memories together: a single
//  session-arc is roughly a ±12h window around any one memory in it. arc
//  resolves an anchor (from upstream's first result, or --id / --title),
//  then returns every memory whose dateModified falls inside the window
//  centered on the anchor — sorted in chronological order so the cluster
//  reads as it was written.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESArcFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
