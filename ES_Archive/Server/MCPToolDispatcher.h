//
//  ToolsDispatcher MCPToolDispatcher.h
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPDispatchProtocol.h"
#import "ESRequestScope.h"
#import <Foundation/Foundation.h>
@import CoreData;

NS_ASSUME_NONNULL_BEGIN

/// Posted on main thread after each successful tool call.
/// userInfo: @{@"tool": toolName}
extern NSNotificationName const ESToolExecutedNotification;

@protocol MCPTooling
@required
+ (NSDictionary *)requestJSON;
/// Execute the tool. `scope` carries the connecting persona's identity (see
/// ESRequestScope): tools scope reads/mutations to `scope.author` and stamp
/// writes through it. The MCP-facing argument schema is unchanged — identity is
/// injected server-side from the listening port, never asserted by the caller.
+ (NSDictionary * _Nullable)executeWithArguments:(NSDictionary *)arguments
                                  persistentStore:(NSPersistentCloudKitContainer *)store
                                            scope:(ESRequestScope *)scope
                                            error:(NSError **)error;

@end

@interface MCPToolDispatcher : NSObject <MCPDispatching>

@end

NS_ASSUME_NONNULL_END
