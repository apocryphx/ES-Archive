//
//  ESMemoryTimelineTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_timeline — temporal retrieval in either direction,
//  along a chosen time axis, optionally within a date window.
//  Supersedes archive_recent (which was newest-by-modified only).
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryTimelineTool : NSObject <MCPTooling>

@end

NS_ASSUME_NONNULL_END
