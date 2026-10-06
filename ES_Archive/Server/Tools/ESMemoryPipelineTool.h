//
//  ESMemoryPipelineTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_pipeline
//
//  Engine-side pipeline entry point. Accepts a pipeline either as an
//  `expression` string in the archive_cli grammar (parsed by
//  ESPipelineParser) or as a pre-parsed `stages` array of
//  {name, positional, flags} dicts; instantiates the matching
//  ESPipelineFilter classes; runs them; returns the response.
//
//  archive_cli (ESMemoryCLITool) is the LLM-facing alias: same grammar,
//  same executor, with entry UUIDs stripped from the results. This tool
//  keeps the structural form and the UUIDs for scripts and graph tools.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryPipelineTool : NSObject <MCPTooling>

/// Parse `expression` and run it. Returns the executor's response, or the
/// archive_cli parse-error shape {error: "parse_error", message, expression}.
/// `stripUUIDs` removes the per-row `uuid` field for LLM-facing callers.
+ (NSDictionary *)executeExpression:(NSString *)expression
                    persistentStore:(NSPersistentCloudKitContainer *)store
                              scope:(ESRequestScope *)scope
                         stripUUIDs:(BOOL)stripUUIDs;

@end

NS_ASSUME_NONNULL_END
