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
//  Role: the socket election (design-decisions/socket-election.md) decides
//  whether this process HOSTS the engine or RELAYS to another host. The role is
//  not fixed for the session: when a relay's host goes away it re-elects
//  (design-decisions/mid-session-reelection.md) and may become the host.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a process that started as a relay re-elects and
/// comes out of it hosting the engine in-process. The stdio app delegate takes on
/// the host's GUI and housekeeping on this. Never posted for the initial election
/// (the delegate reads -servesLocally after -start for that).
extern NSNotificationName const ESEngineDidBecomeHostNotification;

@interface ESEngine : NSObject

+ (instancetype)shared;

/// Persona for this session, from the `--author <name>` launch argument. Set
/// BEFORE -start. nil (no argument) resolves to the target's ESDefaultAuthor.
/// Scopes this session's own requests, and is declared to a shared host so it
/// scopes our relayed requests too.
@property (nonatomic, copy, nullable) NSString *authorOverride;

/// Run the socket election and take the resulting role: connect to a running
/// host and relay, or bind the socket, bring up Core Data, run pending data
/// migrations, and serve peers. The embedder and vector cache stay lazy — they
/// load on the first semantic call — so spawn-to-ready stays well under a second.
/// Main thread.
- (void)start;

/// YES when this process runs the engine IN-PROCESS — it won the socket election
/// as host, or it is standalone with no peer to relay to. NO when it relays to
/// another host. Valid only after -start; can flip NO → YES on a re-election
/// (ESEngineDidBecomeHostNotification), never YES → NO. The stdio app shows its
/// GUI iff this is YES, so the UI's FRCs and ESToolExecutedNotification are always
/// co-located with the engine that fires them (see
/// design-decisions/uds-adaptation-from-template.md).
@property (nonatomic, readonly) BOOL servesLocally;

/// Handle one parsed JSON-RPC envelope. Returns the full response
/// envelope ({jsonrpc, id, result|error}), or nil for messages that
/// expect no response (notifications/* and client responses).
/// Thread-safe; callable concurrently from any queue EXCEPT the main queue
/// (dispatch funnels to main, and a re-election runs there).
/// If the relay's host has gone away, this blocks while the re-election runs and
/// then serves the request from the new role; a request that provably never
/// reached the old host is retried once.
- (nullable NSDictionary *)handleRequest:(NSDictionary *)rpc;

/// Save any pending Core Data changes while continuing to serve. Idempotent;
/// no-op when relaying. Used by a host that lingers for its peers after its own
/// stdio session ended.
- (void)saveContext;

/// Final shutdown: stop serving peers (closes their connections and unlinks the
/// socket, so they re-elect against a clean path) and save any pending Core Data
/// changes. Idempotent — called from the stdin-EOF/SIGTERM drain and again from
/// applicationWillTerminate.
- (void)flushAndSave;

@end

NS_ASSUME_NONNULL_END
