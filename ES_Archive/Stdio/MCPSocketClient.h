//
//  MCPSocketClient.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Client side of the engine's UNIX-domain-socket transport. When an ES Archive
//  Server is already running (it bound the socket in the shared App Group
//  container), the stdio front-end connects here and relays JSON-RPC to that one
//  shared engine — instead of loading its own Core Data stack + embedder. N
//  Claude sessions then share a single engine process.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (on the main queue, object = the client) when the shared engine host
/// closes the connection — detected either by the idle EOF watcher or by a request
/// that hits EOF. The relay does not die on this: ESEngine re-runs the socket
/// election (reconnect to the next host, or bind and load the engine itself), so
/// the Claude session on stdin keeps its server. See
/// design-decisions/mid-session-reelection.md. A slow host (a request timeout) is
/// NOT a disconnect and never posts this. The engine host never posts it (it has no
/// client). Kept AppKit-free here so the transport stays unit-testable.
extern NSNotificationName const MCPSocketClientHostDisconnectedNotification;

/// JSON-RPC error codes in the envelopes -sendRequest: returns when the relay
/// cannot complete a request. The caller uses them to decide whether a retry
/// against a re-elected host is safe.
///   Timeout        — the host took longer than the client timeout. It may still be
///                    executing the request: do NOT retry (a second store would
///                    duplicate). The connection is closed to prevent a late reply
///                    desyncing the stream.
///   ConnectionLost — the request never reached the host (connection already
///                    closed, or the write failed). Safe to retry on a new host.
///   ReplyLost      — the host closed the connection after the request was sent
///                    and before replying. Outcome unknown: do NOT retry blindly.
extern const NSInteger MCPSocketClientErrorTimeout;         // -32000
extern const NSInteger MCPSocketClientErrorConnectionLost;  // -32001
extern const NSInteger MCPSocketClientErrorReplyLost;       // -32002

@interface MCPSocketClient : NSObject

/// Connects to the engine socket in the App Group container. If `author` is
/// non-nil, sends the one-line author handshake so the host scopes this
/// connection to that persona. Returns nil if the group is unavailable or no
/// server is listening — the caller then falls back to hosting in-process.
+ (nullable instancetype)connectWithAuthor:(nullable NSString *)author;

/// Serialize an rpc, send it, and (for requests — those carrying an "id") read
/// and return the response envelope. Notifications (no "id") are fire-and-forget
/// and return nil without waiting. Thread-safe: calls are serialized on the wire.
/// On a transport failure returns a JSON-RPC error envelope for the id (never nil
/// for a request — see the error codes above), and the connection is closed.
- (nullable NSDictionary *)sendRequest:(NSDictionary *)rpc;

/// YES until the connection is known to be unusable: the host closed it, a
/// request timed out, or -close was called. A caller that sees NO right after a
/// -sendRequest: knows that request's failure was terminal for this connection.
@property (readonly, getter=isConnected) BOOL connected;

/// Close the socket now. Idempotent. Waits for an in-flight request to release
/// the wire, and for the EOF watcher to be torn down, before the fd is closed —
/// so the fd number can never be closed under a reader or reused while a stale
/// reference to it exists. Safe from any thread except the EOF watcher's own.
- (void)close;

@end

NS_ASSUME_NONNULL_END
