//
//  ESMemoryCLITool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_cli
//
//  The Unix-pipeline surface Claude and every other client use:
//  archive_cli("lfind --tag X | w2vgrep 'concept' | head 5"). Parses the
//  expression with ESPipelineParser and runs it through the same executor
//  as archive_pipeline, with entry UUIDs stripped from the results.
//
//  Engine-side so both apps offer it: ES Archive MCP (stdio) lists it
//  first, ES Archive Server (HTTP) lists it like any other tool — one
//  grammar, one parser, one set of man pages that is true everywhere
//  (design-decisions/pipeline-unification.md).
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryCLITool : NSObject <MCPTooling>
@end

NS_ASSUME_NONNULL_END
