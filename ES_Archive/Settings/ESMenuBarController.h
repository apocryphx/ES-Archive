//
//  ESMenuBarController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Owns the menu-bar NSStatusItem. The header label is kept in sync with
//  the live MCPServer port via KVO on `boundPortNumber`. Menu actions
//  forward to the AppDelegate / MCPServer rather than duplicating logic.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESMenuBarController : NSObject

/// Installs the status item and starts observing the server port.
- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
