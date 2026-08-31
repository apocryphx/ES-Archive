//
//  ESMemoryGrepTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_grep
//  Line-addressed pattern search across a memory's text surfaces
//  (body and/or attachments). The grep tool I wish I had on the inside.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryGrepTool : NSObject <MCPTooling>
@end

NS_ASSUME_NONNULL_END
