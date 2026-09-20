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

/// Builds the connector .mcpb, writes it to +appSupportFolder and hands it to
/// Claude Desktop so the user gets the install prompt. Falls back to revealing
/// the file in Finder if Claude Desktop is missing or refuses.
+ (void)connectToClaudeDesktopFromWindow:(nullable NSWindow *)window;

// ── Shared with ESSkillInstallController (both targets) ──────────────────────
// Everything below is target-neutral: it names Claude Desktop, not this binary.

/// Claude Desktop, resolved by bundle identifier — never by file-type handler,
/// because ChatGPT also claims .skill and Launch Services hands the default
/// to whichever app registered last. nil when Claude Desktop is not installed.
+ (nullable NSURL *)claudeDesktopURL;

/// ~/Library/Application Support/ES Archive — a stable, app-owned folder for
/// files handed to other apps (the connector, the .skill packages). Created on
/// demand.
+ (NSURL *)appSupportFolder;

/// Open `files` in Claude Desktop, activating it for its install prompt(s).
/// If Claude Desktop is not installed or refuses, reveals the first file in
/// Finder and shows an alert built from `failureMessage`, so the user can
/// double-click it by hand.
+ (void)openInClaudeDesktop:(NSArray<NSURL *> *)files
                 fromWindow:(nullable NSWindow *)window
                    failure:(NSString *)failureMessage;

/// Path of THIS app's executable — the stdio server itself. Every client's
/// configuration is built from it, so it is install-location-proof.
+ (NSString *)serverExecutablePath;

/// mcp.json config for LM Studio (and any stdio MCP host), generated against
/// +serverExecutablePath, with `--author` set to ESLMStudioDefaultAuthor.
+ (NSString *)lmStudioConfigJSON;

/// Puts +lmStudioConfigJSON on the general pasteboard.
+ (void)copyLMStudioConfigToPasteboard;

/// Puts +serverExecutablePath on the general pasteboard, for hosts whose
/// configuration is a form with a command field (ChatGPT desktop).
+ (void)copyServerExecutablePathToPasteboard;

/// Shell-quoted registration command for the user to run in Terminal.
/// Prefers the CLI bundled with the registered ChatGPT/Codex desktop app;
/// otherwise uses `codex` from the user's Terminal PATH. Never executes it.
+ (NSString *)chatGPTSetupCommand;

/// The `--author` value each generated configuration carries. The stdio
/// engine defaults to "Claude" when the flag is absent, so every non-Claude
/// client must declare its persona or its entries land in Claude's.
extern NSString * const ESLMStudioDefaultAuthor;   // "LM Studio"
extern NSString * const ESChatGPTDefaultAuthor;    // "ChatGPT"

@end

NS_ASSUME_NONNULL_END
