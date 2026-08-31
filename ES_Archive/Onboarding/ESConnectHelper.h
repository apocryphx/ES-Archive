//
//  ESConnectHelper.h
//  ES Archive — standalone (App Store) UI
//
//  Stateless helpers that wire this app into local MCP hosts. Used by the
//  chameleon's ESRoleStandaloneApp face — never in stdio-server mode.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESConnectHelper : NSObject

// EVERYTHING HERE IS STDIO ONLY — ESStdioConnectController.
//
// It all builds its configuration from this app's own
// executable path, which is only meaningful in the MCP target, where the
// running binary IS the stdio server. The Server binary excludes the Stdio
// sources, so a configuration generated against it points a client at a process
// that never speaks JSON-RPC — a connection that fails silently. Call these ONLY
// from ESStdioConnectController; the Server app's pane (ESHTTPConnectController)
// builds an HTTP URL from the bound port instead.

/// Copies the bundled connector .mcpb to a temp location and hands it to
/// Claude Desktop (its registered file handler) so the user gets the install
/// prompt. Falls back to revealing the file in Finder if no handler responds.
+ (void)connectToClaudeDesktopFromWindow:(nullable NSWindow *)window;

/// mcp.json config for LM Studio (and any stdio MCP host), generated against
/// THIS app's current executable path — install-location-proof.
+ (NSString *)lmStudioConfigJSON;

/// Puts +lmStudioConfigJSON on the general pasteboard.
+ (void)copyLMStudioConfigToPasteboard;

@end

NS_ASSUME_NONNULL_END
