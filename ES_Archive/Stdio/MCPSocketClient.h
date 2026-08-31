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

/// Posted (on the main queue) when the shared engine host closes the connection —
/// detected either by the idle EOF watcher or by a request that hits EOF. A CLI
/// relay cannot function without its host and does not reconnect (unlike the HTTP
/// bridge), so the app should terminate on this: the stdio pipes close and the MCP
/// client (Claude) surfaces a clean disconnect, instead of the relay lingering as
/// a headless zombie that blocks the app from relaunching. The engine host never
/// posts it (it has no client). Kept AppKit-free here so the transport stays unit-
/// testable; ESStdioAppDelegate owns the terminate.
extern NSNotificationName const MCPSocketClientHostDisconnectedNotification;

@interface MCPSocketClient : NSObject

/// Connects to the engine socket in the App Group container. If `author` is
/// non-nil, sends the one-line author handshake so the host scopes this
/// connection to that persona. Returns nil if the group is unavailable or no
/// server is listening — the caller then falls back to hosting in-process.
+ (nullable instancetype)connectWithAuthor:(nullable NSString *)author;

/// Serialize an rpc, send it, and (for requests — those carrying an "id") read
/// and return the response envelope. Notifications (no "id") are fire-and-forget
/// and return nil without waiting. Thread-safe: calls are serialized on the wire.
/// Returns nil on a socket error.
- (nullable NSDictionary *)sendRequest:(NSDictionary *)rpc;

@end

NS_ASSUME_NONNULL_END
