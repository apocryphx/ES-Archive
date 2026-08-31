//
//  MCPServer.h
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import "MCPDispatchProtocol.h"

@class ESRequestScope;

NS_ASSUME_NONNULL_BEGIN


/**
 A singleton server responsible for managing client connections and dispatching events.
 
 Use `sharedInstance` to access the global server, then call `start:` to begin serving and `stop` to shut it down. You can also use `restart:` to perform a stop/start cycle.
 
 The server maintains a mapping of method names to dispatcher instances (subclasses of `MCPAbstractDispatcher`) that handle incoming requests.
 
 - Threading:
   Request handling occurs on background queues managed by the underlying web server. Access to internal SSE writer storage is synchronized during broadcasting.
 */
@interface MCPServer : NSObject

@property (strong) NSArray <NSNumber*> *customPorts;

/**
 The URL at which the server is currently reachable (e.g. `http://localhost:59123`),
 or a URL with port 0 when the server is not running.

 KVO-compliant: observers are notified whenever `-start:` / `-stop` / `-restart:` change the bound port.
 */
@property (readonly) NSURL* serverURL;

/**
 The currently bound TCP port, or nil if the server is not running.

 KVO-compliant: observers are notified whenever `-start:` / `-stop` / `-restart:` change the bound port.
 This is the single source of truth for the live port — any UI showing the server URL should
 observe this key (or `serverURL`) rather than caching a value at startup.
 */
@property (readonly, nullable) NSNumber *boundPortNumber;

/**
 All active listeners, one per bound (port → persona) row, ordered as bound.
 Each entry is a dictionary with keys:
   - @"port"   NSNumber  — the TCP port
   - @"author" NSString  — the persona served on that port
   - @"jwt"    NSNumber  — BOOL, whether the port requires a Cloudflare Access JWT
 Empty when the server is not running. For display: the multi-port server has
 no single host:port, so UI should enumerate this rather than use boundPortNumber.
 */
@property (readonly) NSArray<NSDictionary<NSString *, id> *> *activeBindings;

/// Unavailable. Use `sharedInstance` to access the global server instance.
- (instancetype)init NS_UNAVAILABLE;

/// Unavailable. Use `sharedInstance` to access the global server instance.
- (instancetype)new NS_UNAVAILABLE;

/**
 Returns the shared server instance.
 
 @return A process-wide singleton instance of `MCPServer`.
 */
+ (instancetype)sharedInstance;

/**
 Starts the server if it is not already running.
 
 The server attempts to bind to a set of common developer ports and succeeds on the first available port.

 Errors are reported in the `MCPServerErrorDomain` (for example, code 1002 indicates that no configured port could be bound).
 
 @param error On failure, set to an error describing why the server could not start.
 @return YES if the server started successfully; NO otherwise.
 */
- (BOOL)start:(NSError * _Nullable * _Nullable)error;

/**
 Stops the server if it is running. Safe to call multiple times.
 */
- (void)stop;

/**
 Restarts the server by stopping (if needed) and starting it again.

 Errors are reported in the `MCPServerErrorDomain` and mirror those produced by `-start:`.
 
 @param error On failure, set to an error describing why the server could not restart.
 @return YES if the server restarted successfully; NO otherwise.
 */
- (BOOL)restart:(NSError * _Nullable * _Nullable)error;

/**
 Pushes a broadcast event to all connected clients.
 
 The event dictionary must be JSON‑serializable; non‑JSON types will cause serialization to fail and no event will be sent.
 
 @param event A dictionary representing the event payload. Keys and values should be property list–compatible.
 */
- (void)pushEventToClients:(NSDictionary *)event;

/**
 Returns the list of all available dispatcher class names that the server can use.
 
 @return An array of class name strings for dispatcher types.
 */
+ (NSArray<NSString *> *)allDispatchClassNames;

/**
 Returns the current mapping of method names to dispatcher instances.
 
 @return A mutable dictionary keyed by method name with values of type `MCPAbstractDispatcher`.
 */
+ (NSDictionary<NSString *, id <MCPDispatching> > *)dispatchMapForMethods;

/**
 Dispatch one parsed JSON-RPC request to its method's dispatcher and return the
 result payload (or nil, with `outError` set, on failure). The shared entry
 point behind every transport — the HTTP routes, and the UNIX-socket listener.
 Runs on the main thread (Core Data viewContext is main-queue bound).
 */
- (nullable NSDictionary *)dispatchJSONRPC:(NSDictionary *)json
                                     scope:(ESRequestScope *)scope
                                     error:(NSError * _Nullable * _Nullable)outError;

@end

NS_ASSUME_NONNULL_END

