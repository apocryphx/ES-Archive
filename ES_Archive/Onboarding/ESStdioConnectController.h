//
//  ESStdioConnectController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESOnboardingWindowController.h"

NS_ASSUME_NONNULL_BEGIN

/// The Connect window as the MCP app presents it: a one-click Claude Desktop
/// connector, a copyable Terminal setup command and manual ChatGPT setup, and an
/// mcp.json for LM Studio and other stdio hosts.
///
/// All three are generated against this app's own executable path, which is sound
/// here and only here — the MCP binary is the stdio server (same Mach-O, serves
/// stdio when spawned with pipes). MCP-target only; the Server app opens
/// ESHTTPConnectController instead.
@interface ESStdioConnectController : ESOnboardingWindowController
@end

NS_ASSUME_NONNULL_END
