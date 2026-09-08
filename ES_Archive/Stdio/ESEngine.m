//
//  ESEngine.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESEngine.h"
#import "ESCoreDataStack.h"
#import "MCPSocketClient.h"
#import "MCPUnixSocketServer.h"
#import "ESLog.h"
#import "ESRequestScope.h"
#import "ESTagMigration.h"
#import "ESVectorEngine.h"
#import "ESDeduplicator.h"
#import "MCPDispatchProtocol.h"

NSNotificationName const ESEngineDidBecomeHostNotification = @"ESEngineDidBecomeHostNotification";

@interface ESEngine ()
@property (strong) NSDictionary<NSString *, id<MCPDispatching>> *dispatchMap;
@property (strong) ESRequestScope *scope;
// When non-nil, a shared ES Archive Server owns the engine and we relay to it
// over the socket instead of hosting Core Data + embedders in this process.
@property (strong, nullable) MCPSocketClient *remote;
// Core dispatch under an explicit scope. -handleRequest: uses our own session
// scope; the socket host calls this with each peer connection's persona.
- (nullable NSDictionary *)handleRequest:(NSDictionary *)rpc scope:(ESRequestScope *)scope;
@end

@implementation ESEngine {
    // Role change gate. While a re-election is in flight, stdio requests park on
    // this condition instead of racing the dead client or a half-loaded engine.
    NSCondition *_roleCondition;
    BOOL         _reelecting;   // guarded by _roleCondition
}

+ (instancetype)shared {
    static ESEngine *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ESEngine alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _roleCondition = [NSCondition new];
    }
    return self;
}

#pragma mark - Startup

/// Keep in sync with +[MCPServer allDispatchClassNames] in Server/MCPServer.m
/// (the HTTP transport, not compiled into this target). Both transports must
/// route the same method surface to the same dispatchers.
+ (NSArray<NSString *> *)dispatchClassNames {
    return @[
        @"MCPCoreDispatcher", @"MCPToolDispatcher", @"MCPResourcesDispatcher",
        @"MCPPromptsDispatcher", @"MCPLoggingDispatcher",
        @"MCPNotificationsDispatcher"
    ];
}

- (void)start {
    // A relay whose host closes the connection re-elects rather than dying with
    // it. The client posts on the main queue; the election itself runs on main
    // too, but the waiter must not (see -reelectReplacing:), so hop off first.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(hostDisconnected:)
                                               name:MCPSocketClientHostDisconnectedNotification
                                             object:nil];
    [self electAndConnect];
}

/// The election and the role it yields. Runs on the main thread — at launch from
/// -start, and again from -reelectReplacing: after a relay loses its host. Safe to
/// run more than once: the engine loads at most once (-loadEngineIfNeeded), and
/// MCPUnixSocketServer re-binds cleanly after a -stop.
- (void)electAndConnect {
    // 0. If an ES Archive Server is already running, it owns the one shared
    //    engine. Connect and relay to it — and skip the whole local bring-up
    //    below, so this stdio process never loads Core Data or the embedder.
    //    That is the point of the socket: N Claude sessions, one engine.
    self.remote = [MCPSocketClient connectWithAuthor:self.authorOverride];
    if (self.remote) {
        ESLog(@"[ESEngine] using shared engine over socket — local engine NOT loaded");
        return;
    }
    ESLog(@"[ESEngine] no shared engine found — racing to host");

    // 1. Win the election BEFORE loading anything. Binding the socket first is
    //    what makes one-engine-per-user hold even on a simultaneous cold start:
    //    whichever process binds first hosts and loads the engine below; every
    //    other racer sees the bound socket and relays WITHOUT ever loading Core
    //    Data or the embedder. (Previously all racers loaded the engine first and
    //    the losers kept it as a ~475 MB idle fallback — the whole point of the
    //    socket, defeated on a dead-heat start.)
    MCPUnixSocketServer *srv = [MCPUnixSocketServer sharedInstance];
    NSError *electErr = nil;
    BOOL elected = [srv electAsHostWithError:&electErr];

    if (elected && !srv.isListening) {
        // A peer bound the socket between our connect-probe and our bind — relay
        // to it and stop here. No engine load: this session stays relay-weight.
        self.remote = [MCPSocketClient connectWithAuthor:self.authorOverride];
        if (self.remote) {
            ESLog(@"[ESEngine] a peer won the host race — relaying to it (engine NOT loaded)");
            return;
        }
        ESLog(@"[ESEngine] peer won the race but connect failed — loading a standalone engine");
    } else if (!elected) {
        // No App Group container to rendezvous on: can neither host nor relay.
        // Degrade to a private per-session engine (the App Group precondition —
        // a healthy install shows the socket; see design-decisions/socket-election.md).
        ESLog(@"[ESEngine] shared socket unavailable (%@) — private per-session engine",
              electErr.localizedDescription ?: @"no App Group");
    }
    // Otherwise we bound the socket and are the host: fall through to load, serve.

    // 2. Bring up the engine. Only a process that reaches here loads it (the host,
    //    or a standalone fallback), so a lost-race relay never pays for Core Data
    //    or the embedder.
    [self loadEngineIfNeeded];

    // 3. If we bound the socket, start serving peers now that the engine is ready.
    //    Connections that arrived while we loaded waited in the listen backlog and
    //    are served the instant we begin accepting. A standalone fallback (no App
    //    Group) has no socket and serves only its own stdio session.
    if (srv.isListening) {
        [srv serveWithRequestHandler:^NSDictionary *(NSDictionary *rpc, NSString *author, BOOL (^isClientConnected)(void)) {
            // Cooperative shedding: if the peer's whole session already closed, don't
            // spend the engine (a cold embedder is seconds) and don't mutate the store
            // for a departed session. See design-decisions/uds-adaptation-from-template.md.
            if (isClientConnected && !isClientConnected()) {
                ESLog(@"[ESEngine] shedding request for departed peer");
                return nil;
            }
            // Dispatch each peer's request under ITS persona (nil → our default),
            // never under our own session's author.
            return [ESEngine.shared handleRequest:rpc scope:[ESRequestScope scopeWithAuthor:author]];
        }];
        ESLog(@"[ESEngine] hosting the shared engine for peer sessions at %@", srv.socketPath);
    } else {
        ESLog(@"[ESEngine] running standalone in-process (no peers)");
    }

    // Backfill (encoding vectors for embeddable memories that synced in without
    // one) is NOT done here — it runs once per host in ESStdioAppDelegate right
    // after -start (or on ESEngineDidBecomeHostNotification), the stdio analogue
    // of the HTTP app's applicationDidFinishLaunching. Kept out of here so a relay
    // (which returns above, engine never loaded) can't trigger it; only the
    // elected host, which loaded the engine, backfills. Newly stored memories
    // still get their vector at store time regardless.
}

/// Core Data, migrations, dedup, the vector cache, the dispatch map. Once per
/// process: a host loads here at launch; a relay that re-elects into hosting
/// loads here mid-session. ESCoreDataStack.shared creates the
/// NSPersistentCloudKitContainer with history tracking + remote-change
/// notifications, which is what lets concurrent instances share one store.
- (void)loadEngineIfNeeded {
    if (self.dispatchMap) return;

    ESCoreDataStack *stack = [ESCoreDataStack shared];

    // One-time tag migration, same as the HTTP app's launch path.
    [ESTagMigration runIfNeededWithContext:stack.viewContext];

    // Automatic deduplication — the archive's integrity guard. Only the elected
    // host reaches this point, so exactly one writer runs it. Idempotent regardless.
    [[ESDeduplicator shared] start];

    // Load the retrieval cache. Despite the name this is cheap — it fetches the
    // active embedder's vectors into RAM (a few MB); the CoreML model itself still
    // lazy-loads on the first encode call. Without this, topK: sees an empty cache
    // and every semantic search returns zero results.
    [[ESVectorEngine shared] warmCache];

    // This session's persona: --author if given, else nil which resolves through
    // +[CDMemory defaultAuthor] to the target's ESDefaultAuthor ("Claude"). Peers
    // relaying to us carry their OWN author per connection.
    self.scope = [ESRequestScope scopeWithAuthor:self.authorOverride];

    // Dispatch map — same registry the HTTP transport builds.
    NSMutableDictionary<NSString *, id<MCPDispatching>> *map = [NSMutableDictionary dictionary];
    for (NSString *className in [ESEngine dispatchClassNames]) {
        Class cls = NSClassFromString(className);
        id<MCPDispatching> instance = cls.new;
        for (NSString *method in [cls methodNames]) {
            if (map[method]) NSLog(@"[ESEngine] duplicate method: %@", method);
            map[method] = instance;
        }
    }
    self.dispatchMap = [map copy];
    ESLog(@"[ESEngine] dispatch map: %lu methods registered — author: %@",
          (unsigned long)self.dispatchMap.count, self.scope.author);
}

#pragma mark - Role

- (BOOL)servesLocally {
    // remote is non-nil exactly when we relay to a host; nil means we run the
    // engine ourselves — won the election as host, or standalone with no peer.
    return self.remote == nil;
}

#pragma mark - Mid-session re-election

// The host we relay to closed the connection (posted on the main queue by
// MCPSocketClient). Re-elect off-main: the election runs ON main, and the gate in
// -reelectReplacing: must never be waited on from there.
- (void)hostDisconnected:(NSNotification *)note {
    MCPSocketClient *dead = note.object;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self reelectReplacing:dead];
    });
}

/// Replace `dead` (the relay connection that failed) by re-running the election:
/// connect to whichever host now owns the socket, or bind it and load the engine
/// ourselves. Idempotent and serialized — the first caller to notice a dead host
/// runs it, everyone else waits on the gate and finds the new role. If `dead` is
/// no longer our remote (someone already replaced it, or we are already the
/// host), this is a no-op. Never call on the main thread.
- (void)reelectReplacing:(MCPSocketClient *)dead {
    NSAssert(!NSThread.isMainThread, @"re-election is waited on off-main and run on main");

    [_roleCondition lock];
    while (_reelecting) [_roleCondition wait];
    if (self.remote != dead) {
        [_roleCondition unlock];
        return;
    }
    _reelecting = YES;
    [_roleCondition unlock];

    fprintf(stderr, "[es-archive-mcp] shared engine host went away — re-electing\n");

    // Close the dead client here, off-main: -close waits for any request still on
    // its wire to let go, which (for a host that is wedged rather than gone) can
    // take up to the client timeout. Main must not be the one waiting for that.
    [dead close];

    ExecuteOnMainThread(^id {
        self.remote = nil;
        [self electAndConnect];
        if (self.remote) {
            fprintf(stderr, "[es-archive-mcp] re-elected — relaying to the new host\n");
        } else {
            fprintf(stderr, "[es-archive-mcp] re-elected — this session now hosts the engine\n");
            [NSNotificationCenter.defaultCenter postNotificationName:ESEngineDidBecomeHostNotification
                                                              object:self];
        }
        return nil;
    });

    [_roleCondition lock];
    _reelecting = NO;
    [_roleCondition broadcast];
    [_roleCondition unlock];
}

/// The relay connection to use for a request, once any in-flight re-election has
/// settled. nil means serve locally.
- (nullable MCPSocketClient *)remoteAfterPendingElection {
    [_roleCondition lock];
    while (_reelecting) [_roleCondition wait];
    MCPSocketClient *remote = self.remote;
    [_roleCondition unlock];
    return remote;
}

#pragma mark - Dispatch

- (nullable NSDictionary *)handleRequest:(NSDictionary *)rpc {
    if (![rpc isKindOfClass:NSDictionary.class]) return nil;

    // Client responses carry no method — acknowledge silently, matching the
    // HTTP transport.
    if (!rpc[@"method"]) return nil;

    NSDictionary *reply = nil;
    for (int attempt = 0; attempt < 2; attempt++) {
        MCPSocketClient *remote = [self remoteAfterPendingElection];

        // Our own engine, our own session's persona.
        if (!remote) return [self handleRequest:rpc scope:self.scope];

        // Relay to the shared engine. sendRequest: returns nil for notifications
        // (no id) and an error envelope for a transport failure; both are the
        // correct outcome for the stdio writer as long as the connection lives.
        reply = [remote sendRequest:rpc];
        if (remote.isConnected) return reply;

        // The host is gone (EOF) or wedged (timeout): re-elect, then decide about
        // THIS request. Retry only when it provably never reached the old host —
        // ConnectionLost, or a notification whose write failed. A Timeout means the
        // host may still be executing it, and a ReplyLost means it did and we don't
        // know the outcome; a second copy of a store would duplicate. Those return
        // their error to the client, which can retry deliberately.
        [self reelectReplacing:remote];
        BOOL neverDelivered = (reply == nil)
            || [reply[@"error"][@"code"] isEqual:@(MCPSocketClientErrorConnectionLost)];
        if (!neverDelivered) return reply;
    }
    return reply;
}

- (nullable NSDictionary *)handleRequest:(NSDictionary *)rpc scope:(ESRequestScope *)scope {
    id rpcId = rpc[@"id"];
    id method = rpc[@"method"];
    if (!method) return nil;

    NSDictionary *params = [rpc[@"params"] isKindOfClass:NSDictionary.class] ? rpc[@"params"] : @{};

    // Same main-thread funnel as -[MCPServer dispatchJSONRPC:scope:error:] —
    // the Core Data viewContext is main-queue bound. Callers on the stdio
    // work queue block here exactly like GCDWebServer's worker threads do in
    // the HTTP target.
    __block NSDictionary *result = nil;
    __block NSError *error = nil;
    ExecuteOnMainThread(^id {
        if (![method isKindOfClass:NSString.class]) {
            error = [NSError errorWithDomain:@"MCPError"
                                        code:-32600
                                    userInfo:@{NSLocalizedDescriptionKey : @"Invalid Request"}];
            return nil;
        }

        ESLog(@"[MCP-stdio] %@", method);

        id<MCPDispatching> dispatcher = self.dispatchMap[method];
        if (!dispatcher) {
            ESLog(@"[MCP-stdio] method not found: %@", method);
            error = [NSError errorWithDomain:@"MCPError"
                                        code:-32601
                                    userInfo:@{NSLocalizedDescriptionKey : @"Method not found"}];
            return nil;
        }

        result = [dispatcher handleMethod:method params:params scope:scope error:&error];
        if (error) {
            NSLog(@"[MCP-stdio] %@ error: %@", method, error.localizedDescription);
        }
        return nil;
    });

    // Notifications (no id) — dispatched, but nothing goes on the wire.
    if (!rpcId) return nil;

    if (error) {
        return @{
            @"jsonrpc" : @"2.0",
            @"id" : rpcId,
            @"error" : @{
                @"code" : @(error.code),
                @"message" : error.localizedDescription ?: @"Error"
            }
        };
    }
    return @{
        @"jsonrpc" : @"2.0",
        @"id" : rpcId,
        @"result" : result ?: @{@"status" : @"ok"}
    };
}

#pragma mark - Shutdown

- (void)saveContext {
    // The shared server owns the store; nothing local to save when relaying.
    if (self.remote) return;
    // viewContext is main-queue bound; ExecuteOnMainThread makes this safe from
    // any queue. -saveContext is a no-op when nothing changed.
    ExecuteOnMainThread(^id {
        [[ESCoreDataStack shared] saveContext];
        return nil;
    });
}

- (void)flushAndSave {
    // The shared server owns the store; nothing local to flush when relaying.
    if (self.remote) return;

    // If we were hosting peers, stop the socket listener BEFORE the final save:
    // closes peer connections and unlinks the socket file, so the peers re-elect
    // against a clean path instead of probing our corpse (stale-socket recovery
    // covers a crash; a clean exit shouldn't need it). Idempotent — this runs
    // from both the stdio drain and applicationWillTerminate.
    [[MCPUnixSocketServer sharedInstance] stop];

    [self saveContext];
}

@end
