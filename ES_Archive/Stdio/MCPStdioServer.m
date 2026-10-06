//
//  MCPStdioServer.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPStdioServer.h"
#import "ESEngine.h"
#import "MCPFraming.h"
#import "MCPUnixSocketServer.h"
#import <AppKit/AppKit.h>
#import <stdatomic.h>

static int gRPCFileDescriptor = -1;

@interface MCPStdioServer () {
    atomic_flag _drainStarted;
    atomic_bool _sessionEnded;
}
@property (strong) dispatch_queue_t readQueue;
@property (strong) dispatch_queue_t writeQueue;
@property (strong) dispatch_queue_t workQueue;
@property (strong) NSFileHandle    *stdinHandle;
@property (strong) NSFileHandle    *rpcOutHandle;
@property (strong) NSMutableData   *inputBuffer;
@property (strong) dispatch_source_t sigtermSource;
/// YES after our stdio session ended while peer sessions still relay through
/// this engine: we stay up for them (see -finishShutdown). Main thread only.
@property (nonatomic) BOOL lingering;
@end

@implementation MCPStdioServer

+ (void)setRPCFileDescriptor:(int)fd {
    gRPCFileDescriptor = fd;
}

+ (instancetype)shared {
    static MCPStdioServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[MCPStdioServer alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _readQueue   = dispatch_queue_create("esm.stdio.read",  DISPATCH_QUEUE_SERIAL);
    _writeQueue  = dispatch_queue_create("esm.stdio.write", DISPATCH_QUEUE_SERIAL);
    _workQueue   = dispatch_queue_create("esm.stdio.work",  DISPATCH_QUEUE_CONCURRENT);
    _stdinHandle = [NSFileHandle fileHandleWithStandardInput];
    _rpcOutHandle = (gRPCFileDescriptor >= 0)
        ? [[NSFileHandle alloc] initWithFileDescriptor:gRPCFileDescriptor closeOnDealloc:NO]
        : [NSFileHandle fileHandleWithStandardOutput];
    _inputBuffer = [NSMutableData data];
    return self;
}

- (void)start {
    fprintf(stderr, "[es-archive-mcp] stdio server starting (pid=%d)\n", getpid());

    [self installSIGTERMSource];

    __weak typeof(self) weak = self;
    self.stdinHandle.readabilityHandler = ^(NSFileHandle *h) {
        __strong typeof(weak) s = weak;
        if (!s) return;

        NSData *chunk = nil;
        @try { chunk = [h availableData]; }
        @catch (NSException *e) {
            fprintf(stderr, "[es-archive-mcp] stdin read exception: %s\n",
                    e.reason.UTF8String ?: "?");
        }

        if (!chunk.length) {
            h.readabilityHandler = nil;
            fprintf(stderr, "[es-archive-mcp] stdin EOF — draining and terminating\n");
            [s drainAndTerminate];
            return;
        }

        dispatch_async(s.readQueue, ^{
            [s.inputBuffer appendData:chunk];
            [s drainLines];
        });
    };
}

#pragma mark - Shutdown

/// main() sets SIGTERM to SIG_IGN so this dispatch source owns delivery.
/// The client (Claude Desktop / Claude Code) may end a session either by
/// closing our stdin or by signaling — both funnel into the same drain.
- (void)installSIGTERMSource {
    self.sigtermSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                                self.readQueue);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(self.sigtermSource, ^{
        fprintf(stderr, "[es-archive-mcp] SIGTERM — draining and terminating\n");
        __strong typeof(weak) s = weak;
        [s drainAndTerminate];
    });
    dispatch_resume(self.sigtermSource);
}

- (BOOL)sessionEnded { return atomic_load(&_sessionEnded); }

- (void)drainAndTerminate {
    atomic_store(&_sessionEnded, true);
    // EOF and SIGTERM can both arrive in one shutdown; drain exactly once. A
    // later signal while we linger for peers is honored only once no peer
    // session depends on this engine any more.
    if (atomic_flag_test_and_set(&_drainStarted)) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self terminateIfIdle]; });
        return;
    }

    // Drain the queues in order before deciding how to end:
    //   1. readQueue   (serial)     — process any pending input chunks
    //   2. workQueue   (concurrent) — barrier: finish handleLine for every
    //                                 line drained in step 1
    //   3. writeQueue  (serial)     — flush every response those lines wrote
    //   4. finishShutdown (main)    — save, then terminate or linger
    // Without step 1, the barrier on workQueue can fire before late chunks have
    // even been pushed onto workQueue, and a tool response gets lost in the
    // shutdown race.
    dispatch_async(self.readQueue, ^{
        dispatch_barrier_async(self.workQueue, ^{
            dispatch_async(self.writeQueue, ^{
                dispatch_async(dispatch_get_main_queue(), ^{ [self finishShutdown]; });
            });
        });
    });
}

/// Main thread. Our stdio session is over and every reply is flushed. If this
/// process hosts the shared engine and other sessions are relaying through it,
/// stopping now would take all of them down with us — they would each re-elect,
/// and one would reload the engine (Core Data + embedder) from cold. Claude Desktop
/// makes this the common case: it spawns the server twice at startup and closes
/// the first instance within a second, and that first instance usually won the
/// bind. So a host lingers for its peers and exits once the last one leaves.
/// See design-decisions/mid-session-reelection.md.
- (void)finishShutdown {
    MCPUnixSocketServer *srv = [MCPUnixSocketServer sharedInstance];
    NSUInteger peers = ([ESEngine shared].servesLocally && srv.isListening) ? srv.connectionCount : 0;
    if (peers > 0) {
        fprintf(stderr, "[es-archive-mcp] stdio session ended, but %lu peer session(s) still use this engine — lingering as host\n",
                (unsigned long)peers);
        self.lingering = YES;
        [[ESEngine shared] saveContext];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(peersBecameIdle:)
                                                   name:MCPUnixSocketServerDidBecomeIdleNotification
                                                 object:nil];
        return;
    }
    [self terminateNow];
}

// The last peer left. Give a re-electing peer its reconnect window — it can drop
// and come straight back — before concluding nobody needs us.
- (void)peersBecameIdle:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self terminateIfIdle];
    });
}

- (void)terminateIfIdle {
    if (!self.lingering) return;
    if ([MCPUnixSocketServer sharedInstance].connectionCount > 0) return;
    fprintf(stderr, "[es-archive-mcp] last peer session left — lingering host terminating\n");
    [self terminateNow];
}

// Main thread. Core Data is saved (and the socket stopped, so any straggler
// re-elects against a clean path) before the process dies.
- (void)terminateNow {
    self.lingering = NO;
    [[ESEngine shared] flushAndSave];
    [NSApp terminate:nil];
}

#pragma mark - Line framing

- (void)drainLines {
    static const uint8_t nl = '\n';
    while (YES) {
        NSRange r = [self.inputBuffer rangeOfData:[NSData dataWithBytes:&nl length:1]
                                          options:0
                                            range:NSMakeRange(0, self.inputBuffer.length)];
        if (r.location == NSNotFound) break;

        NSData *lineData = [self.inputBuffer subdataWithRange:NSMakeRange(0, r.location)];
        [self.inputBuffer replaceBytesInRange:NSMakeRange(0, r.location + 1)
                                    withBytes:NULL length:0];
        if (!lineData.length) continue;

        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length) dispatch_async(self.workQueue, ^{ [self handleLine:line]; });
    }
}

- (void)write:(NSString *_Nullable)line {
    if (!line) return;
    dispatch_async(self.writeQueue, ^{
        NSData *out = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSError *err = nil;
        if (![self.rpcOutHandle writeData:out error:&err]) {
            fprintf(stderr, "[es-archive-mcp] rpc write failed: %s\n",
                    err.localizedDescription.UTF8String ?: "?");
        }
    });
}

#pragma mark - Line dispatch

- (void)handleLine:(NSString *)line {
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];

    if (![msg isKindOfClass:[NSDictionary class]]) {
        [self write:ESMBJSONRPCError(nil, -32700, @"Parse error")];
        return;
    }

    NSString *method = [msg[@"method"] isKindOfClass:NSString.class] ? msg[@"method"] : nil;
    id rpcId = msg[@"id"];
    NSString *output = nil;

    if ([method isEqualToString:@"tools/list"]) {
        // The stdio host curates the order only: the engine's archive_cli is
        // moved to index 0 ahead of the other schemas, preserving the
        // bridge's presentation exactly.
        output = [self toolsListResponseForMessage:msg rpcId:rpcId];
    }

    if (!output) {
        // Everything else — initialize, notifications/*, resources/*, and
        // every tools/call — goes straight to the in-process engine. This
        // host no longer rewrites anything on the way in: archive_cli is an
        // engine tool (Server/Pipeline/ESPipelineParser) and relative dates
        // are resolved by the engine (Server/ESDateArgument).
        //
        // The call is synchronous on this concurrent work queue for the same
        // reason the bridge forwarded synchronously: stdin EOF triggers the
        // drain immediately, and the workQueue barrier only guarantees a
        // response for work that has already completed. Multiple inbound
        // lines still run on parallel worker threads.
        NSDictionary *response = [ESEngine.shared handleRequest:msg];
        if (response) output = ESMBEncodeJSON(response);
        // nil response → notification or client response: write nothing
        // (the stdio equivalent of the HTTP transport's bodyless 202).
    }

    if (output) [self write:output];
}

#pragma mark - tools/list merge

- (NSString *)toolsListResponseForMessage:(NSDictionary *)msg rpcId:(id)rpcId {
    NSDictionary *response = [ESEngine.shared handleRequest:msg];

    NSArray *engineTools = nil;
    id result = response[@"result"];
    if ([result isKindOfClass:NSDictionary.class]) {
        id tools = ((NSDictionary *)result)[@"tools"];
        if ([tools isKindOfClass:NSArray.class]) engineTools = tools;
    }
    if (!engineTools) {
        // Engine returned an error envelope (or nothing) — pass it through
        // rather than inventing a tool list.
        return response ? ESMBEncodeJSON(response)
                        : ESMBJSONRPCError(rpcId, -32603, @"tools/list failed");
    }

    // The engine (in-process or the elected host) supplies archive_cli like
    // any other tool; this host only moves it to index 0 so Claude sees the
    // composable surface first, as the bridge always presented it.
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:engineTools.count];
    NSDictionary *cli = nil;
    for (NSDictionary *t in engineTools) {
        if (![t isKindOfClass:NSDictionary.class]) continue;
        if (!cli && [t[@"name"] isEqual:@"archive_cli"]) {
            cli = t;
        } else {
            [merged addObject:t];
        }
    }
    if (cli) [merged insertObject:cli atIndex:0];
    return ESMBJSONRPCResult(rpcId, @{ @"tools": merged });
}

@end
