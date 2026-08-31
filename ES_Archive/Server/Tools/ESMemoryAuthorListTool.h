//
//  ESMemoryAuthorListTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_author_list
//  Returns distinct author names from actual CDMemory records.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryAuthorListTool : NSObject <MCPTooling>
@end

NS_ASSUME_NONNULL_END
