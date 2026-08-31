//
//  ESEngine.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  In-process facade over the memory engine for the stdio MCP host.
//
//  The HTTP target (ES Archive Server) hosts the same engine behind
//  GCDWebServer; this facade is the stdio target's equivalent of the
//  transport layer in Server/MCPServer.m — same dispatch map, same
//  main-thread funnel, same response envelopes — minus everything HTTP
//  (ports, SSE sessions, JWT gates). Server/MCPServer.m is not compiled
//  into this target.
//
//  Identity: single persona. One immutable ESRequestScope is built at
//  -start from +[CDMemory defaultAuthor] (the ESDefaultAuthor Info.plist
//  key, "Claude" in this target) and threaded into every dispatch.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESEngine : NSObject

+ (instancetype)shared;

/// Persona for this session, from the `--author <name>` launch argument. Set
/// BEFORE -start. nil (no argument) resolves to the target's ESDefaultAuthor.
/// Scopes this session's own requests, and is declared to a shared host so it
/// scopes our relayed requests too.
@property (nonatomic, copy, nullable) NSString *authorOverride;

/// Bring up Core Data and run pending data migrations. The embedder and
/// vector cache stay lazy — they load on the first semantic call — so
/// spawn-to-ready stays well under a second.
- (void)start;

/// YES when this process runs the engine IN-PROCESS — it won the socket election
/// as host, or it is standalone with no peer to relay to. NO when it relays to
/// another host. Valid only after -start. The stdio app shows its GUI iff this is
/// YES, so the UI's FRCs and ESToolExecutedNotification are always co-located with
/// the engine that fires them (see design-decisions/uds-adaptation-from-template.md).
@property (nonatomic, readonly) BOOL servesLocally;

/// Handle one parsed JSON-RPC envelope. Returns the full response
/// envelope ({jsonrpc, id, result|error}), or nil for messages that
/// expect no response (notifications/* and client responses).
/// Thread-safe; callable concurrently from any queue.
- (nullable NSDictionary *)handleRequest:(NSDictionary *)rpc;

/// Save any pending Core Data changes. Idempotent — called from the
/// stdin-EOF/SIGTERM drain and again from applicationWillTerminate.
- (void)flushAndSave;

@end

NS_ASSUME_NONNULL_END
