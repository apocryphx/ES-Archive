//
//  MCPServer.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

/**
 MCPServer

 JSON-RPC server on GCDWebServer implementing MCP transports.

 Two modes, decided PER LISTENER by ESServerConfig.requiresJWTForPort: (which
 falls back to the global ESServerConfig.requireAccessHeader for any port
 without an explicit flag):

 - Default mode (no JWT) — full endpoint surface, no auth:
     POST /mcp                  Streamable HTTP transport (2025-03-26 spec)
     GET  /mcp                  Returns 405 (no server-initiated SSE)
     DELETE /mcp                Returns 405 (no session termination)
     GET  /sse                  Legacy SSE transport (2024-11-05 spec)
     POST /messages?sessionId=  Legacy SSE message endpoint
     POST /rpc                  Direct JSON-RPC (for curl testing)
   GET /personas (discovery) is always registered, in both modes.

 - JWT Required mode — only POST /mcp (+ 405 stubs) and GET /personas; each
   /mcp request must carry a Cf-Access-Jwt-Assertion header (presence-checked).
   Intended as a cloudflared upstream behind Cloudflare Access.

 Each persona's port can run a different mode (e.g. a public persona behind
 JWT, a local-only persona open). The per-binding flag is captured at -start:
 to decide which endpoints to register and is checked inside each /mcp handler;
 changing it applies on restart.
 */

#import "MCPServer.h"
#import "ESCoreDataStack.h" // for ExecuteOnMainThread
#import "ESServerConfig.h"
#import "ESRequestScope.h"
#import "ESLog.h"
#import "MCPCoreDispatcher.h"
#import "MCPLoggingDispatcher.h"
#import "MCPNotificationsDispatcher.h"
#import "MCPPromptsDispatcher.h"
#import "MCPResourcesDispatcher.h"
#import "MCPToolDispatcher.h"

@import GCDWebServer;

/// One listener = one persona. Each binding owns a GCDWebServer (GCDWebServer is
/// one-port-per-instance) bound to a single port, tagged with the canonical
/// author for that port. The author is captured into the listener's handler
/// closures, so the channel a request arrives on declares its identity.
@interface ESServerBinding : NSObject
@property(nonatomic, strong) GCDWebServer *server;
@property(nonatomic, assign) UInt16 port;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, assign) BOOL requireJWT; // per-route Cf-Access gate
@end

@implementation ESServerBinding
@end

@interface MCPServer ()
/// One binding per (port → author) row. Replaces the former single server.
@property(nonatomic, strong) NSMutableArray<ESServerBinding *> *bindings;
@property(nonatomic, strong) NSHashTable *activeWriters;

/// MCP SSE sessions: sessionId → writer block (available when stream is idle)
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, GCDWebServerBodyReaderCompletionBlock>
        *sessionWriters;

/// Queued SSE payloads waiting for a writer: sessionId → array of NSData
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSMutableArray<NSData *> *>
        *pendingPayloads;
@end

@implementation MCPServer

+ (instancetype)sharedInstance {
  static MCPServer *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = self.new;
    sharedInstance.bindings = [NSMutableArray new];
    sharedInstance.activeWriters = [NSHashTable weakObjectsHashTable];
    sharedInstance.sessionWriters = [NSMutableDictionary new];
    sharedInstance.pendingPayloads = [NSMutableDictionary new];
  });
  return sharedInstance;
}

+ (NSArray<NSNumber *> *)commonPorts {
  return @[ @(5000), @(8080), @(8000), @(8888) ];
}

/// With N listeners the legacy single-value KVO surface (boundPortNumber /
/// serverURL) reports the "primary" binding: the one on the effective default
/// port, else the first that bound. Existing UI observers keep working.
- (ESServerBinding *)primaryBinding {
  if (self.bindings.count == 0) return nil;
  UInt16 effective = [ESServerConfig effectivePort];
  for (ESServerBinding *b in self.bindings) {
    if (b.port == effective) return b;
  }
  return self.bindings.firstObject;
}

- (NSNumber *)boundPortNumber {
  ESServerBinding *b = [self primaryBinding];
  return b ? @(b.port) : nil;
}

- (NSArray<NSDictionary<NSString *, id> *> *)activeBindings {
  NSMutableArray *out = [NSMutableArray array];
  for (ESServerBinding *b in self.bindings) {
    [out addObject:@{
      @"port":   @(b.port),
      @"author": b.author ?: @"",
      @"jwt":    @(b.requireJWT),
    }];
  }
  return out;
}

- (NSURL *)serverURL {
  return [self primaryBinding].server.serverURL;
}

- (NSMutableDictionary<NSString *, id> *)serverOptionsForPort:(UInt16)port {
  // DISPATCH_QUEUE_PRIORITY_HIGH (QoS: User-initiated) prevents priority
  // inversion when the main thread (User-interactive) calls -stop during
  // app termination, which internally dispatch_syncs on this queue.
  return [@{
    GCDWebServerOption_Port : @(port),
    GCDWebServerOption_BindToLocalhost : @YES,
    GCDWebServerOption_DispatchQueuePriority : @(DISPATCH_QUEUE_PRIORITY_HIGH)
  } mutableCopy];
}

/// Defense-in-depth presence check for the Cloudflare Access JWT header.
/// Signature is not verified in this version — CF Access at the edge is the
/// real gate. Header name is matched case-insensitively because cloudflared's
/// casing is not contractually fixed.
- (BOOL)hasAccessAssertionHeader:(GCDWebServerRequest *)request {
  for (NSString *key in request.headers.allKeys) {
    if ([key caseInsensitiveCompare:@"Cf-Access-Jwt-Assertion"] == NSOrderedSame) {
      NSString *v = request.headers[key];
      return v.length > 0;
    }
  }
  return NO;
}

#pragma mark - Dispatch Map

+ (NSArray<NSString *> *)allDispatchClassNames {
  return @[
    @"MCPCoreDispatcher", @"MCPToolDispatcher", @"MCPResourcesDispatcher",
    @"MCPPromptsDispatcher", @"MCPLoggingDispatcher",
    @"MCPNotificationsDispatcher"
  ];
}

+ (NSDictionary<NSString *, id<MCPDispatching>> *)dispatchMapForMethods {
  static NSDictionary<NSString *, id<MCPDispatching>> *dispatchMap = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSMutableDictionary<NSString *, id<MCPDispatching>> *map =
        [NSMutableDictionary dictionary];
    for (NSString *className in [self allDispatchClassNames]) {
      Class cls = NSClassFromString(className);
      id<MCPDispatching> instance = cls.new;
      for (NSString *method in [cls methodNames]) {
        if (map[method])
          NSLog(@"[MCPServer] duplicate method: %@", method);
        map[method] = instance;
      }
    }
    dispatchMap = [map copy];
    ESLog(@"[MCPServer] dispatch map: %lu methods registered",
          (unsigned long)dispatchMap.count);
  });
  return dispatchMap;
}

#pragma mark - JSON-RPC Dispatch (shared by /rpc and /messages)

- (NSDictionary *)dispatchJSONRPC:(NSDictionary *)json
                            scope:(ESRequestScope *)scope
                            error:(NSError **)outError {
  // All dispatch runs on the main thread — Core Data viewContext is main-queue
  // bound.
  __block NSDictionary *result = nil;
  __block NSError *innerError = nil;

  // Fail safe: a memory tool must never run without a persona scope. A nil
  // scope (e.g. a future code path that forgets to pass one) falls back to the
  // build default author rather than running unscoped across all personas.
  ESRequestScope *effectiveScope = scope ?: [ESRequestScope scopeWithAuthor:nil];

  void (^work)(void) = ^{
    NSString *method = json[@"method"];
    NSDictionary *params = json[@"params"] ?: @{};

    if (!method || ![method isKindOfClass:NSString.class]) {
      innerError = [NSError
          errorWithDomain:@"MCPError"
                     code:-32600
                 userInfo:@{NSLocalizedDescriptionKey : @"Invalid Request"}];
      return;
    }

    ESLog(@"[MCP] %@", method);

    id<MCPDispatching> dispatcher = [MCPServer dispatchMapForMethods][method];
    if (!dispatcher) {
      ESLog(@"[MCP] method not found: %@", method);
      innerError = [NSError
          errorWithDomain:@"MCPError"
                     code:-32601
                 userInfo:@{NSLocalizedDescriptionKey : @"Method not found"}];
      return;
    }

    result = [dispatcher handleMethod:method params:params scope:effectiveScope error:&innerError];

    if (innerError) {
      NSLog(@"[MCP] %@ error: %@", method, innerError.localizedDescription);
    }
  };

  if ([NSThread isMainThread]) {
    work();
  } else {
    dispatch_sync(dispatch_get_main_queue(), work);
  }

  if (outError)
    *outError = innerError;
  return result;
}

#pragma mark - Streamable HTTP Transport (POST/GET/DELETE /mcp)

- (void)registerStreamableHTTPEndpointOnBinding:(ESServerBinding *)binding {
  __weak typeof(self) weakSelf = self;
  GCDWebServer *server = binding.server;
  // Capture the immutable author (not the binding) to avoid a binding→server→
  // block→binding retain cycle; build one scope per request from it.
  NSString *author = binding.author;
  // Per-route JWT gate captured by value, same pattern as author.
  BOOL requireJWT = binding.requireJWT;

  // POST /mcp — client sends JSON-RPC, server returns JSON directly.
  // When JWT mode is on, every request must carry Cf-Access-Jwt-Assertion.
  [server
      addHandlerForMethod:@"POST"
                     path:@"/mcp"
             requestClass:[GCDWebServerDataRequest class]
             processBlock:^GCDWebServerResponse *(
                 GCDWebServerRequest *request) {
               if (requireJWT &&
                   ![weakSelf hasAccessAssertionHeader:request]) {
                 ESLog(@"[HTTP] POST /mcp → 401 (missing Cf-Access-Jwt-Assertion)");
                 return [GCDWebServerResponse responseWithStatusCode:401];
               }
               ESLog(@"[HTTP] POST /mcp — Content-Type: %@, Accept: %@, "
                     @"Content-Length: %lu",
                     request.contentType ?: @"(none)",
                     [request.headers objectForKey:@"Accept"] ?: @"(none)",
                     (unsigned long)request.contentLength);

               NSData *requestData = [(GCDWebServerDataRequest *)request data];
               if (requestData.length == 0) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               NSError *parseError = nil;
               id parsed = [NSJSONSerialization JSONObjectWithData:requestData
                                                           options:0
                                                             error:&parseError];
               if (!parsed || parseError) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               // Accept single message or JSON-RPC batch array
               BOOL isBatch = [parsed isKindOfClass:[NSArray class]];
               NSArray *messages = isBatch ? parsed : @[ parsed ];

               NSMutableArray *responses = [NSMutableArray new];
               BOOL hasRequests = NO;

               // Identity is declared by the channel: this listener's author.
               ESRequestScope *scope =
                   [ESRequestScope scopeWithAuthor:author];

               for (NSDictionary *json in messages) {
                 if (![json isKindOfClass:[NSDictionary class]])
                   continue;

                 id rpcId = json[@"id"];
                 NSString *method = json[@"method"];

                 ESLog(@"[HTTP-IN]  %@ id=%@", method ?: @"(response)",
                       rpcId ?: @"(notification)");

                 // Client responses (no method) — just acknowledge
                 if (!method)
                   continue;

                 NSError *dispatchError = nil;
                 NSDictionary *result =
                     [weakSelf dispatchJSONRPC:json scope:scope error:&dispatchError];

                 // Notifications (no id) — dispatch but no response
                 if (!rpcId) {
                   ESLog(@"[HTTP-OUT] (notification, no response)");
                   continue;
                 }

                 hasRequests = YES;

                 NSDictionary *rpcResponse;
                 if (dispatchError) {
                   rpcResponse = @{
                     @"jsonrpc" : @"2.0",
                     @"id" : rpcId,
                     @"error" : @{
                       @"code" : @(dispatchError.code),
                       @"message" : dispatchError.localizedDescription
                           ?: @"Error"
                     }
                   };
                 } else {
                   rpcResponse = @{
                     @"jsonrpc" : @"2.0",
                     @"id" : rpcId,
                     @"result" : result ?: @{@"status" : @"ok"}
                   };
                 }

                 [responses addObject:rpcResponse];
               }

               // Only notifications/responses — return 202 with no body (per
               // spec)
               if (!hasRequests) {
                 return [GCDWebServerResponse responseWithStatusCode:202];
               }

               // Return single response or batch array matching input shape
               id responseBody = isBatch ? responses : responses.firstObject;
               GCDWebServerDataResponse *resp = [GCDWebServerDataResponse
                   responseWithJSONObject:responseBody];
               [resp setValue:@"2026-03-26" forAdditionalHeader:@"mcp-version"];
               return resp;
             }];

  // GET /mcp — server-initiated SSE stream (not supported)
  [server
      addHandlerForMethod:@"GET"
                     path:@"/mcp"
             requestClass:[GCDWebServerRequest class]
             processBlock:^GCDWebServerResponse *(
                 GCDWebServerRequest *request) {
               if (requireJWT &&
                   ![weakSelf hasAccessAssertionHeader:request]) {
                 return [GCDWebServerResponse responseWithStatusCode:401];
               }
               ESLog(@"[HTTP] GET /mcp → 405 (no server-initiated SSE)");
               return [GCDWebServerResponse responseWithStatusCode:405];
             }];

  // DELETE /mcp — session termination (not supported)
  [server addHandlerForMethod:@"DELETE"
                              path:@"/mcp"
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse *(
                          GCDWebServerRequest *request) {
                        if (requireJWT &&
                            ![weakSelf hasAccessAssertionHeader:request]) {
                          return [GCDWebServerResponse responseWithStatusCode:401];
                        }
                        ESLog(@"[HTTP] DELETE /mcp → 405");
                        return
                            [GCDWebServerResponse responseWithStatusCode:405];
                      }];
}

#pragma mark - SSE Writer Management

/// Send payload immediately if a writer is available, otherwise queue it.
- (void)sendSSEPayload:(NSData *)payload forSession:(NSString *)sessionId {
  @synchronized(self.sessionWriters) {
    GCDWebServerBodyReaderCompletionBlock writer =
        self.sessionWriters[sessionId];
    if (writer) {
      [self.sessionWriters removeObjectForKey:sessionId];
      writer(payload, nil);
    } else {
      NSMutableArray *queue = self.pendingPayloads[sessionId];
      if (!queue) {
        queue = [NSMutableArray new];
        self.pendingPayloads[sessionId] = queue;
      }
      [queue addObject:payload];
    }
  }
}

/// Called when a new writer becomes available from the asyncStreamBlock.
- (void)writerBecameAvailable:(GCDWebServerBodyReaderCompletionBlock)write
                   forSession:(NSString *)sessionId {
  @synchronized(self.sessionWriters) {
    NSMutableArray *queue = self.pendingPayloads[sessionId];
    if (queue.count > 0) {
      NSData *payload = queue.firstObject;
      [queue removeObjectAtIndex:0];
      if (queue.count == 0)
        [self.pendingPayloads removeObjectForKey:sessionId];
      write(payload, nil);
    } else {
      self.sessionWriters[sessionId] = write;
    }
  }
}

#pragma mark - MCP SSE Transport (GET /sse) — Default-mode only

- (void)registerSSEEndpointOnBinding:(ESServerBinding *)binding {
  __weak typeof(self) weakSelf = self;
  GCDWebServer *server = binding.server;
  UInt16 bindingPort = binding.port;

  [server
      addHandlerForMethod:@"GET"
                     path:@"/sse"
             requestClass:[GCDWebServerRequest class]
        asyncProcessBlock:^(GCDWebServerRequest *request,
                            GCDWebServerCompletionBlock completionBlock) {
          ESLog(@"[SSE] GET /sse — Accept: %@, Headers: %@",
                [request.headers objectForKey:@"Accept"] ?: @"(none)",
                request.headers.allKeys);

          NSString *sessionId = NSUUID.UUID.UUIDString;
          ESLog(@"[MCP-SSE] new session: %@", sessionId);

          __block BOOL sentEndpoint = NO;

          GCDWebServerStreamedResponse *response = [GCDWebServerStreamedResponse
              responseWithContentType:@"text/event-stream"
                     asyncStreamBlock:^(
                         GCDWebServerBodyReaderCompletionBlock write) {
                       if (!sentEndpoint) {
                         sentEndpoint = YES;
                         // Point clients back at THIS listener's port, not the
                         // aggregate primary, so a persona stays on its own port.
                         NSString *endpoint = [NSString
                             stringWithFormat:
                                 @"http://localhost:%u/messages?sessionId=%@",
                                 bindingPort, sessionId];
                         NSString *payload = [NSString
                             stringWithFormat:@"event: endpoint\ndata: %@\n\n",
                                              endpoint];
                         write([payload dataUsingEncoding:NSUTF8StringEncoding],
                               nil);
                       } else {
                         [weakSelf writerBecameAvailable:write
                                              forSession:sessionId];
                       }
                     }];

          [response setValue:@"no-cache" forAdditionalHeader:@"Cache-Control"];
          [response setValue:@"keep-alive" forAdditionalHeader:@"Connection"];
          completionBlock(response);
        }];
}

#pragma mark - MCP Message Endpoint (POST /messages) — Default-mode only

- (void)registerMessageEndpointOnBinding:(ESServerBinding *)binding {
  __weak typeof(self) weakSelf = self;
  GCDWebServer *server = binding.server;
  NSString *author = binding.author;

  [server
      addHandlerForMethod:@"POST"
                     path:@"/messages"
             requestClass:[GCDWebServerDataRequest class]
             processBlock:^GCDWebServerResponse *(
                 GCDWebServerRequest *request) {
               NSString *sessionId = request.query[@"sessionId"];
               if (!sessionId) {
                 return [GCDWebServerResponse responseWithStatusCode:400];
               }

               // Parse JSON-RPC
               NSData *requestData = [(GCDWebServerDataRequest *)request data];
               if (requestData.length == 0) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               NSError *parseError = nil;
               NSDictionary *json =
                   [NSJSONSerialization JSONObjectWithData:requestData
                                                   options:0
                                                     error:&parseError];
               if (!json || parseError) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               id rpcId = json[@"id"];

               ESLog(@"[MCP-IN]  %@ id=%@", json[@"method"] ?: @"(response)",
                     rpcId ?: @"(notification)");

               // Dispatch with this listener's persona identity.
               NSError *dispatchError = nil;
               ESRequestScope *scope =
                   [ESRequestScope scopeWithAuthor:author];
               NSDictionary *result = [weakSelf dispatchJSONRPC:json
                                                          scope:scope
                                                          error:&dispatchError];

               // JSON-RPC notifications have no "id" — dispatch but never
               // respond.
               if (!rpcId) {
                 ESLog(@"[MCP-OUT] 202 (notification, no response)");
                 return [GCDWebServerResponse responseWithStatusCode:202];
               }

               // Build JSON-RPC response for requests (have an "id")
               NSDictionary *rpcResponse;
               if (dispatchError) {
                 rpcResponse = @{
                   @"jsonrpc" : @"2.0",
                   @"id" : rpcId,
                   @"error" : @{
                     @"code" : @(dispatchError.code),
                     @"message" : dispatchError.localizedDescription ?: @"Error"
                   }
                 };
               } else {
                 rpcResponse = @{
                   @"jsonrpc" : @"2.0",
                   @"id" : rpcId,
                   @"result" : result ?: @{@"status" : @"ok"}
                 };
               }

               // Log the full response
               NSData *jsonData = [NSJSONSerialization
                   dataWithJSONObject:rpcResponse
                              options:NSJSONWritingPrettyPrinted
                                error:nil];
               NSString *jsonString =
                   [[NSString alloc] initWithData:jsonData
                                         encoding:NSUTF8StringEncoding];
               ESLog(@"[MCP-OUT] SSE response for id=%@:\n%@", rpcId,
                     jsonString);

               // Push response via SSE (compact, no pretty-print)
               NSData *compactData =
                   [NSJSONSerialization dataWithJSONObject:rpcResponse
                                                   options:0
                                                     error:nil];
               NSString *compactString =
                   [[NSString alloc] initWithData:compactData
                                         encoding:NSUTF8StringEncoding];
               NSString *ssePayload =
                   [NSString stringWithFormat:@"event: message\ndata: %@\n\n",
                                              compactString];
               [weakSelf
                   sendSSEPayload:[ssePayload
                                      dataUsingEncoding:NSUTF8StringEncoding]
                       forSession:sessionId];

               return [GCDWebServerResponse responseWithStatusCode:202];
             }];
}

#pragma mark - Legacy JSON-RPC (POST /rpc) — Default-mode only, for curl testing

- (void)registerMCPEndpointOnBinding:(ESServerBinding *)binding {
  __weak typeof(self) weakSelf = self;
  GCDWebServer *server = binding.server;
  NSString *author = binding.author;
  [server
      addHandlerForMethod:@"POST"
                     path:@"/rpc"
             requestClass:[GCDWebServerDataRequest class]
             processBlock:^GCDWebServerResponse *(
                 GCDWebServerRequest *postRequest) {
               NSData *requestData =
                   [(GCDWebServerDataRequest *)postRequest data];
               if (requestData.length == 0) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               NSError *parseError = nil;
               NSDictionary *json =
                   [NSJSONSerialization JSONObjectWithData:requestData
                                                   options:0
                                                     error:&parseError];
               if (!json || parseError) {
                 return [weakSelf errorResponse:-32700
                                        message:@"Parse error"
                                             id:nil];
               }

               id rpcId = json[@"id"];

               ESLog(@"[RPC-IN]  %@ id=%@", json[@"method"] ?: @"(response)",
                     rpcId ?: @"(none)");

               NSError *dispatchError = nil;
               ESRequestScope *scope =
                   [ESRequestScope scopeWithAuthor:author];
               NSDictionary *result = [weakSelf dispatchJSONRPC:json
                                                          scope:scope
                                                          error:&dispatchError];

               NSDictionary *rpcResponse;
               if (dispatchError) {
                 rpcResponse = @{
                   @"jsonrpc" : @"2.0",
                   @"id" : rpcId ?: [NSNull null],
                   @"error" : @{
                     @"code" : @(dispatchError.code),
                     @"message" : dispatchError.localizedDescription ?: @"Error"
                   }
                 };
               } else {
                 rpcResponse = @{
                   @"jsonrpc" : @"2.0",
                   @"id" : rpcId ?: [NSNull null],
                   @"result" : result ?: @{@"status" : @"ok"}
                 };
               }

               NSData *logData = [NSJSONSerialization
                   dataWithJSONObject:rpcResponse
                              options:NSJSONWritingPrettyPrinted
                                error:nil];
               ESLog(@"[RPC-OUT] %@",
                     [[NSString alloc] initWithData:logData
                                           encoding:NSUTF8StringEncoding]);

               return [GCDWebServerDataResponse
                   responseWithJSONObject:rpcResponse];
             }];
}

#pragma mark - Persona Discovery (GET /personas) — both modes, open

- (void)registerDiscoveryEndpointOnBinding:(ESServerBinding *)binding {
  [binding.server
      addHandlerForMethod:@"GET"
                     path:@"/personas"
             requestClass:[GCDWebServerRequest class]
             processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
               // Read the configured port → author table and emit it as a flat
               // directory, sorted by port. This is the server-sourced persona
               // list a bridge reads to auto-configure; it is intentionally
               // available without the MCP handshake.
               NSDictionary<NSNumber *, NSString *> *map =
                   [ESServerConfig portAuthorMap];
               NSArray<NSNumber *> *ports =
                   [map.allKeys sortedArrayUsingSelector:@selector(compare:)];
               NSMutableArray *personas =
                   [NSMutableArray arrayWithCapacity:ports.count];
               for (NSNumber *portNum in ports) {
                 [personas addObject:@{
                   @"author" : map[portNum],
                   @"port" : portNum,
                 }];
               }
               GCDWebServerDataResponse *resp = [GCDWebServerDataResponse
                   responseWithJSONObject:@{@"personas" : personas}];
               [resp setValue:@"*" forAdditionalHeader:@"Access-Control-Allow-Origin"];
               return resp;
             }];
}

- (GCDWebServerResponse *)errorResponse:(NSInteger)code
                                message:(NSString *)message
                                     id:(id)rpcId {
  return [GCDWebServerDataResponse responseWithJSONObject:@{
    @"jsonrpc" : @"2.0",
    @"id" : rpcId ?: [NSNull null],
    @"error" : @{@"code" : @(code), @"message" : message}
  }];
}

#pragma mark - Push Events (notifications to all SSE clients)

- (void)pushEventToClients:(NSDictionary *)event {
  NSError *err = nil;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:event
                                                     options:0
                                                       error:&err];
  if (!jsonData)
    return;
  NSString *jsonString = [[NSString alloc] initWithData:jsonData
                                               encoding:NSUTF8StringEncoding];
  NSString *payload =
      [NSString stringWithFormat:@"event: message\ndata: %@\n\n", jsonString];
  NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];

  @synchronized(self.sessionWriters) {
    for (NSString *sid in self.sessionWriters.allKeys) {
      [self sendSSEPayload:data forSession:sid];
    }
  }
}

#pragma mark - Lifecycle

// boundPortNumber/serverURL derive from the underlying GCDWebServer, which
// does not post KVO notifications. We post them manually around every state
// change so observers (UI labels, status indicators, etc.) stay in sync.
+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
  if ([key isEqualToString:@"boundPortNumber"] ||
      [key isEqualToString:@"serverURL"]) {
    return NO;
  }
  return [super automaticallyNotifiesObserversForKey:key];
}

- (BOOL)start:(NSError **)error {
  NSError *lastErr = nil;

  // One listener per persona, sourced from the port → author table. The table
  // seeds to {effectivePort : defaultAuthor} when unset, so the single-persona
  // zero-config case binds exactly the same port as before. Each persona binds
  // its declared port exactly — no commonPorts fall-through, which would put a
  // persona on an unpredictable port.
  NSDictionary<NSNumber *, NSString *> *map = [ESServerConfig portAuthorMap];
  NSArray<NSNumber *> *ports =
      [map.allKeys sortedArrayUsingSelector:@selector(compare:)];

  [self willChangeValueForKey:@"boundPortNumber"];
  [self willChangeValueForKey:@"serverURL"];

  NSMutableArray<ESServerBinding *> *newBindings = [NSMutableArray array];

  for (NSNumber *portNum in ports) {
    UInt16 port = portNum.unsignedShortValue;
    NSString *author = map[portNum];

    BOOL bindingJWT = [ESServerConfig requiresJWTForPort:port];

    ESServerBinding *binding = [ESServerBinding new];
    binding.port = port;
    binding.author = author;
    binding.requireJWT = bindingJWT;
    binding.server = [GCDWebServer new];

    // Streamable HTTP /mcp is registered for every binding. When this binding
    // requires JWT, its handlers 401 on a missing Cf-Access-Jwt-Assertion
    // header; otherwise there's no header gate. The legacy + curl-testing
    // endpoints are registered only on open bindings (minimising the public
    // surface for a CF tunnel upstream). The gate is now per-route.
    [self registerStreamableHTTPEndpointOnBinding:binding];
    // Persona discovery — a read-only directory of {author, port}, consumable
    // before the MCP handshake so a client can auto-configure which port to
    // reach a given persona on. Non-sensitive (names + ports only, the
    // configured table — never memory content). Always open, both modes.
    [self registerDiscoveryEndpointOnBinding:binding];
    if (!bindingJWT) {
      [self registerSSEEndpointOnBinding:binding];
      [self registerMessageEndpointOnBinding:binding];
      [self registerMCPEndpointOnBinding:binding];
    }

    NSError *bindErr = nil;
    NSDictionary *opts = [self serverOptionsForPort:port];
    if ([binding.server startWithOptions:opts error:&bindErr]) {
      [newBindings addObject:binding];
      ESLog(@"[MCPServer] bound %@ on localhost:%u — mode: %@", author, port,
            bindingJWT ? @"JWT Required" : @"Default");
    } else {
      lastErr = bindErr;
      ESLog(@"[MCPServer] port %u (%@) unavailable: %@", port, author,
            bindErr.localizedDescription);
    }
  }

  self.bindings = newBindings;

  [self didChangeValueForKey:@"serverURL"];
  [self didChangeValueForKey:@"boundPortNumber"];

  // Best-effort: succeed if at least one persona came up; report an error only
  // when every binding failed.
  BOOL started = (newBindings.count > 0);
  if (!started && error) {
    *error = lastErr
                 ?: [NSError errorWithDomain:@"MCPServerErrorDomain"
                                        code:1002
                                    userInfo:@{
                                      NSLocalizedDescriptionKey :
                                          @"Failed to bind any port"
                                    }];
  }
  return started;
}

- (void)stop {
  [self willChangeValueForKey:@"boundPortNumber"];
  [self willChangeValueForKey:@"serverURL"];
  for (ESServerBinding *binding in self.bindings) {
    [binding.server stop];
  }
  [self.bindings removeAllObjects];
  [self didChangeValueForKey:@"serverURL"];
  [self didChangeValueForKey:@"boundPortNumber"];
}

- (BOOL)restart:(NSError **)error {
  [self stop];
  return [self start:error];
}

@end
