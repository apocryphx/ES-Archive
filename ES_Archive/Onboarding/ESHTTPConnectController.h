//
//  ESHTTPConnectController.h
//  ES Archive Server
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESOnboardingWindowController.h"

NS_ASSUME_NONNULL_BEGIN

/// The Connect window as the Server app presents it: an mcp.json pointing at the
/// HTTP listener on localhost, with a picker for which persona to connect as.
///
/// No Claude Desktop connector and no executable path anywhere — this binary
/// excludes the Stdio sources and cannot serve stdio, so a connector generated
/// against it would hand Claude a process that never speaks JSON-RPC. The
/// Server's connection story is the port, and because a port IS a persona here
/// (the port a request arrives on stamps its authorship), choosing the persona
/// is the same act as choosing the URL.
///
/// SERVER-TARGET ONLY — it reads ESServerConfig, which is excluded from the MCP
/// target, so this file carries a matching exclusion in the project. That is the
/// one place in this codebase where target membership must be edited by hand:
/// the synchronized group adds new files to BOTH targets by default.
@interface ESHTTPConnectController : ESOnboardingWindowController
@end

NS_ASSUME_NONNULL_END
