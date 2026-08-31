//
//  ESStdioStatusItemController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Menu-bar presence for the stdio host: app name + version, a live memory
//  count, Archive Scope, the backup/restore flows, and Quit. In Minimal
//  (menu-bar) mode this item is the only always-present surface — no Dock
//  icon, no visible app menu — so it carries Quit as the sole shut-down
//  affordance. No Dashboard — System Pulse is the HTTP server's cockpit
//  (port status, listener log) and lives in the Server target.
//

#import <Cocoa/Cocoa.h>

// Back Up / Restore / Show Archive Scope are the app delegate's commands; this item's
// menu targets the delegate directly (a background status item has no key-window
// responder chain for First Responder to walk). So the delegate owns one
// implementation shared with the Full-mode main menu, and this controller only builds
// the menu-bar item and the menu around it.
@interface ESStdioStatusItemController : NSObject
@end
