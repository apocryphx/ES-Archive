//
//  MCPUnixSocketServer.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Engine-agnostic UNIX-domain-socket listener for the MCP engine. Same
//  JSON-RPC, newline-delimited framing (identical to the stdio transport), a
//  local socket instead of a TCP port — MAS-safe (see ../../REDESIGN.md).
//
//  The singleton is enforced by bind()-exclusivity: exactly one process binds
//  the socket path. Used by TWO hosts, hence the handler block rather than a
//  hardwired engine:
//    * ES Archive Server  — handler forwards to MCPServer's dispatch.
//    * ES Archive MCP      — when no server exists, the first stdio session binds
//                           the socket and serves its peers from ESEngine.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Handle one parsed JSON-RPC request for a given persona `author` (nil = the
/// host's default). Return the full response envelope ({jsonrpc,id,result|error})
/// or nil for notifications / no-response messages. `author` is per-connection:
/// a client declares it once via the author-handshake line right after connect,
/// so peers with different personas never cross.
///
/// `isClientConnected` is a cooperative load-shedding predicate: the handler may
/// call it right before doing the expensive engine work to ask "is the peer that
/// sent this request still on the wire?". It returns NO once the connection has
/// closed (the client's whole session ended) — the handler should then shed the
/// request and return nil rather than mutate the store for a departed session.
/// See design-decisions/uds-adaptation-from-template.md.
typedef NSDictionary * _Nullable (^MCPUnixRequestHandler)(NSDictionary *rpc,
                                                          NSString * _Nullable author,
                                                          BOOL (^isClientConnected)(void));

/// Method name of the one-line author handshake a client sends after connecting
/// ({"jsonrpc":"2.0","method":<this>,"params":{"author":"…"}}). Not forwarded to
/// the handler; it only sets the connection's persona.
extern NSString * const MCPUnixAuthorHandshakeMethod;

/// Posted on the main queue (object = the server) when the last peer connection
/// closes while the server is still listening. Lets a host that is only alive for
/// its peers (a stdio host whose own session has ended — see MCPStdioServer) know
/// it can go. Not posted by -stop. A new peer may connect right after it fires;
/// re-check -connectionCount before acting on it.
extern NSNotificationName const MCPUnixSocketServerDidBecomeIdleNotification;

@interface MCPUnixSocketServer : NSObject

+ (instancetype)sharedInstance;

/// Election + serve. Binds the engine socket; on winning, serves each request
/// via `handler`. Returns YES and begins serving when this process becomes the
/// host; returns YES WITHOUT serving when a live peer already owns the socket
/// (test -isListening to distinguish); returns NO + error on failure.
- (BOOL)startWithRequestHandler:(MCPUnixRequestHandler)handler
                          error:(NSError **)error;

/// Two-phase host bring-up, for a caller that wants to WIN the election BEFORE
/// loading its (expensive) engine — so a process that loses a simultaneous
/// cold-start race never loads the engine at all. -electAsHost runs the same
/// bind()-election as -startWithRequestHandler: but does NOT begin accepting; the
/// caller then loads its engine and calls -serveWithRequestHandler:.
///
/// Returns YES when the election resolved — test -isListening: YES means this
/// process bound the socket (load the engine, then call -serveWithRequestHandler:),
/// NO means a live peer already owns it (connect as a client instead). Returns
/// NO + error only on hard failure (no App Group container, socket()/bind error).
/// While bound-but-not-yet-serving, peer connections wait in the listen backlog
/// and are served the moment -serveWithRequestHandler: begins accepting.
- (BOOL)electAsHostWithError:(NSError **)error;

/// Begin accepting and serving peer connections after a winning -electAsHost.
/// No-op unless this process bound the socket and isn't already serving.
- (void)serveWithRequestHandler:(MCPUnixRequestHandler)handler;

- (void)stop;

/// Resolved socket path (App Group container, else the app's own container).
@property (readonly, nullable) NSString *socketPath;

/// YES when this process bound the socket and is serving.
@property (readonly, getter=isListening) BOOL listening;

/// Number of peer connections currently open. Counts accepted connections whose
/// read source is live; a peer that closed is removed the moment its EOF is read.
@property (readonly) NSUInteger connectionCount;

@end

NS_ASSUME_NONNULL_END
