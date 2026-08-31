//
//  ESRevisionsPipelineFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  revisions — narrow a population to memories that have been revised at
//  least N times (default 1). Read-only. Useful for the "what keeps
//  changing" question:
//
//      lfind --days 30 | revisions --min 3 | sort revised
//      lfind --tag "ES Archive" | revisions | head 10
//
//  Different from archive_revisions (the per-memory MCP tool) in shape:
//  that tool returns a single memory's revision history; this filter
//  returns the population of memories whose revision count meets a
//  threshold, suitable for further pipeline composition.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESRevisionsPipelineFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
