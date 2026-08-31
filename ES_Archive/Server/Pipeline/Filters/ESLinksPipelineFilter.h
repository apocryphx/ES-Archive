//
//  ESLinksPipelineFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  links — pipeline graph-traversal filter. Walks edges outward from every
//  memory in the input population and emits the union of the connected
//  neighbors as the new population. Read-only. Composes naturally:
//
//      lfind --tag "ES Archive" | links --edge contradicts | head 5
//      discover --mode hubs | links --direction out | sort popular
//
//  Different from archive_links (the per-memory MCP tool) in shape: that
//  tool takes a single title and returns rich link metadata for inspection;
//  this filter takes a population and returns a population, suitable for
//  further pipeline composition.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESLinksPipelineFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
