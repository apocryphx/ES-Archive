//
//  ESMemoryReferenceTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_reference — typed, durable pointers to external resources.
//  Successor to archive_attachment: a reference points, it does not contain.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryReferenceTool : NSObject <MCPTooling>

@end

NS_ASSUME_NONNULL_END
