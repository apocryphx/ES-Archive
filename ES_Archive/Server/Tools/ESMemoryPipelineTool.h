//
//  ESMemoryPipelineTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_pipeline
//
//  Server-side pipeline executor entry point. Accepts a parsed pipeline
//  from the bridge as an array of {name, positional, flags} stage dicts;
//  instantiates the matching ESPipelineFilter classes; runs them; returns
//  the response.
//
//  This tool is bridge-facing — Claude never calls it directly. The bridge
//  parses the user's CLI string, marshals stages, and invokes this tool.
//  Bridge translates the response back to the user-facing archive_cli shape.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryPipelineTool : NSObject <MCPTooling>
@end

NS_ASSUME_NONNULL_END
