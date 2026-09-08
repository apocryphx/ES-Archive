//
//  test_main.m
//  ES Archive — standalone UDS transport test harness
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Cross-process-shaped, deterministic transport tests that exercise the REAL
//  MCPUnixSocketServer + MCPSocketClient + ESEngineSocket against a private /tmp
//  socket (via the UDS_SOCKET_PATH override), with a stub handler in place of the
//  Core Data engine. Adapted from the UDS-Shared-Engine template's XCTest suite;
//  built with clang (no Xcode target, no Core Data / AppKit) so it runs anywhere:
//
//      Testing/uds-transport/run.sh
//
//  Covers: round-trip, persona handshake, shared state, N-way concurrency, the
//  misbehaving-client catalog (byte-dribble, pipelined, garbage/non-object JSON,
//  oversized value, slam-shut mid-reply, connection flood), and the two changes
//  this branch adds — client timeout returning a clean error (not a hang) and
//  cooperative shedding of a departed client's request — plus the host-loss
//  surface mid-session re-election is built on (design-decisions/
//  mid-session-reelection.md): disconnect notification, typed error codes, idle
//  notification, re-bind of the freed path.
//

#import <Foundation/Foundation.h>
#import "MCPUnixSocketServer.h"
#import "MCPSocketClient.h"
#import "ESEngineSocket.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <stdatomic.h>

// ───────────────────────── mini test framework ─────────────────────────
static int gFail = 0, gPass = 0;
static void ok(BOOL cond, const char *name) {
    if (cond) { gPass++; fprintf(stderr, "  ✓ %s\n", name); }
    else      { gFail++; fprintf(stderr, "  ✗ %s\n", name); }
}

// ───────────────────────── stub engine (the handler) ─────────────────────────
static atomic_int gCounter = 0;
static atomic_bool gShedDidShed = false, gShedDidWork = false;

static NSDictionary *StubReply(id rpcId, NSDictionary *result) {
    if (rpcId == nil) return nil;   // notification
    return @{@"jsonrpc":@"2.0", @"id":rpcId, @"result":result};
}

// The MCPUnixRequestHandler: a trivial in-memory "engine" that echoes enough to
// assert on, honours the shedding predicate, and can simulate slow/gated work.
static MCPUnixRequestHandler StubHandler(void) {
    return ^NSDictionary *(NSDictionary *rpc, NSString *author, BOOL (^isClientConnected)(void)) {
        NSString *method = rpc[@"method"];
        id rpcId = rpc[@"id"];

        if ([method isEqualToString:@"slowshed"]) {
            // Model a request that waits before its work: sleep, THEN check
            // liveness. If the client left during the wait, shed before working.
            usleep(300 * 1000);
            if (isClientConnected && !isClientConnected()) {
                atomic_store(&gShedDidShed, true);
                return nil;                                    // shed — no work, no reply
            }
            atomic_store(&gShedDidWork, true);
            return StubReply(rpcId, @{@"worked":@YES});
        }
        if ([method isEqualToString:@"slow"]) {
            if (isClientConnected && !isClientConnected()) return nil;
            usleep(1000 * 1000);                               // 1s — outlast a tight client timeout
        }

        int n = atomic_fetch_add(&gCounter, 1) + 1;
        return StubReply(rpcId, @{@"method": method ?: @"(nil)",
                                  @"author": author ?: @"(default)",
                                  @"count": @(n)});
    };
}

// ───────────────────────── raw-socket helpers (misbehaving clients) ─────────────────────────
static int RawConnect(void) {
    NSString *path = ESEngineSocketPath();
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr; socklen_t len = 0;
    if (!ESEngineFillSockaddr(&addr, &len, path)) { close(fd); return -1; }
    if (connect(fd, (struct sockaddr *)&addr, len) != 0) { close(fd); return -1; }
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    return fd;
}
static void RawWrite(int fd, NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes; size_t left = d.length;
    while (left) { ssize_t n = write(fd, b, left); if (n <= 0) break; b += n; left -= (size_t)n; }
}
// Read one '\n'-terminated line, or nil on EOF. `buf` is caller-owned and
// preserves bytes read past the newline — essential for pipelined replies that
// arrive coalesced in a single read(). Pass a fresh buffer per connection and
// REUSE it across successive reads on that connection.
static NSDictionary *RawReadReply(int fd, NSMutableData *buf) {
    uint8_t tmp[4096];
    for (;;) {
        NSRange r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) {
            NSData *line = [buf subdataWithRange:NSMakeRange(0, r.location)];
            [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];   // keep the remainder
            id o = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            return [o isKindOfClass:NSDictionary.class] ? o : nil;
        }
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) return nil;
        [buf appendBytes:tmp length:(NSUInteger)n];
    }
}

// ───────────────────────── tests ─────────────────────────
static void test_roundtrip(void) {
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"jsonrpc":@"2.0", @"id":@1, @"method":@"ping"}];
    ok(rep != nil && [rep[@"id"] isEqual:@1] && rep[@"result"] != nil, "round-trip: request → reply");
}

static void test_persona(void) {
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:@"Isolde"];
    NSDictionary *rep = [c sendRequest:@{@"jsonrpc":@"2.0", @"id":@2, @"method":@"who"}];
    ok([rep[@"result"][@"author"] isEqualToString:@"Isolde"], "persona handshake: author scoped per connection");
}

static void test_shared_state(void) {
    // Two independent connections observe the same server-side counter.
    MCPSocketClient *a = [MCPSocketClient connectWithAuthor:nil];
    MCPSocketClient *b = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *r1 = [a sendRequest:@{@"id":@10, @"method":@"x"}];
    NSDictionary *r2 = [b sendRequest:@{@"id":@11, @"method":@"x"}];
    int c1 = [r1[@"result"][@"count"] intValue];
    int c2 = [r2[@"result"][@"count"] intValue];
    ok(c2 == c1 + 1, "shared state: counter advances across connections");
}

static void test_concurrency(void) {
    atomic_store(&gCounter, 0);
    const int K = 8, M = 20;
    dispatch_group_t g = dispatch_group_create();
    dispatch_queue_t q = dispatch_queue_create("test.concurrency", DISPATCH_QUEUE_CONCURRENT);
    __block atomic_int replies = 0;
    for (int k = 0; k < K; k++) {
        dispatch_group_async(g, q, ^{
            MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
            for (int m = 0; m < M; m++) {
                NSDictionary *rep = [c sendRequest:@{@"id":@(m), @"method":@"bump"}];
                if (rep[@"result"][@"count"]) atomic_fetch_add(&replies, 1);
            }
        });
    }
    dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    ok(atomic_load(&replies) == K * M && atomic_load(&gCounter) == K * M,
       "concurrency: 8×20 clients, no lost writes");
}

static void test_byte_dribble(void) {
    int fd = RawConnect();
    NSString *req = @"{\"id\":100,\"method\":\"dribble\"}\n";
    NSData *d = [req dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { write(fd, b + i, 1); usleep(200); }  // one byte at a time
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    ok([rep[@"id"] isEqual:@100], "byte-dribble: framing reassembles across reads");
    close(fd);
}

static void test_pipelined(void) {
    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":201,\"method\":\"a\"}\n{\"id\":202,\"method\":\"b\"}\n");  // two lines, one write
    NSMutableData *buf = [NSMutableData data];   // shared: replies may arrive coalesced
    NSDictionary *r1 = RawReadReply(fd, buf);
    NSDictionary *r2 = RawReadReply(fd, buf);
    ok([r1[@"id"] isEqual:@201] && [r2[@"id"] isEqual:@202], "pipelined: two requests in one write, two replies");
    close(fd);
}

static void test_garbage_json(void) {
    int fd = RawConnect();
    RawWrite(fd, @"this is not json\n");
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    ok([rep[@"error"][@"code"] isEqual:@(-32700)], "garbage JSON: parse error, not a crash");
    close(fd);
}

static void test_nonobject_json(void) {
    int fd = RawConnect();
    RawWrite(fd, @"[1,2,3]\n");
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    ok([rep[@"error"][@"code"] isEqual:@(-32700)], "non-object JSON: rejected");
    close(fd);
}

static void test_oversized(void) {
    int fd = RawConnect();
    NSMutableString *big = [NSMutableString stringWithCapacity:200000];
    for (int i = 0; i < 200000; i++) [big appendString:@"x"];   // ~200KB, spans many read buffers
    RawWrite(fd, [NSString stringWithFormat:@"{\"id\":300,\"method\":\"big\",\"blob\":\"%@\"}\n", big]);
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    ok([rep[@"id"] isEqual:@300], "oversized value: round-trips across many reads");
    close(fd);
}

static void test_slam_shut(void) {
    // Client sends a slow request then vanishes before the reply — the host will
    // write to a dead fd. Without SIGPIPE handling this signal-kills the process.
    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":400,\"method\":\"slow\"}\n");
    usleep(50 * 1000);
    close(fd);                       // gone while the host sleeps in "slow"
    usleep(1200 * 1000);             // let the host finish and attempt its write
    // If we're still alive, SIGPIPE was handled. Prove the host still serves:
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@401, @"method":@"after"}];
    ok(rep != nil, "slam-shut mid-reply: host survives SIGPIPE and keeps serving");
}

static void test_flood(void) {
    for (int i = 0; i < 200; i++) { int fd = RawConnect(); if (fd >= 0) close(fd); }  // connect/close storm
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@500, @"method":@"alive"}];
    ok(rep != nil, "connection flood: host still accepting afterwards");
}

static void test_client_timeout(void) {
    // A tight client timeout against a 1s "slow" handler must return a clean
    // JSON-RPC error envelope for the id — NOT nil (which would hang the caller).
    setenv("UDS_CLIENT_TIMEOUT", "0.3", 1);
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@600, @"method":@"slow"}];
    unsetenv("UDS_CLIENT_TIMEOUT");
    BOOL cleanError = rep != nil && [rep[@"id"] isEqual:@600] && [rep[@"error"][@"code"] isEqual:@(-32000)];
    ok(cleanError, "client timeout: returns -32000 error envelope, not a hang");
    // Same client is now dead → subsequent request also errors cleanly (no desync).
    NSDictionary *rep2 = [c sendRequest:@{@"id":@601, @"method":@"x"}];
    ok(rep2[@"error"] != nil, "client timeout: dead connection short-circuits, no stream desync");
}

static void test_shedding(void) {
    // Read-driven and deterministic: the handler waits (simulating a queued
    // request), the client leaves during that wait, and the liveness check at
    // the end must shed it — no work, no mutation.
    atomic_store(&gShedDidShed, false);
    atomic_store(&gShedDidWork, false);

    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":700,\"method\":\"slowshed\"}\n");
    usleep(80 * 1000);    // let the host read the request and enter the pre-work delay
    close(fd);            // client leaves before the liveness check fires
    usleep(500 * 1000);   // let the handler finish the delay and check liveness
    ok(atomic_load(&gShedDidShed) && !atomic_load(&gShedDidWork),
       "cooperative shedding: departed client's request dropped before work");
}

static void test_election_defer(void) {
    // A second host on the same live path must DEFER (probe finds a live peer),
    // not clobber the incumbent. Uses a separate path + its own live host.
    NSString *elPath = [NSString stringWithFormat:@"/tmp/es-uds-election-%d.sock", getpid()];
    setenv("UDS_SOCKET_PATH", elPath.fileSystemRepresentation, 1);

    MCPUnixSocketServer *host = [[MCPUnixSocketServer alloc] init];
    NSError *e1 = nil;
    [host startWithRequestHandler:StubHandler() error:&e1];
    ok(host.isListening, "election: first host binds and listens");

    MCPUnixSocketServer *second = [[MCPUnixSocketServer alloc] init];
    NSError *e2 = nil;
    BOOL r = [second startWithRequestHandler:StubHandler() error:&e2];
    ok(r && !second.isListening, "election: second host defers to the live peer (no clobber)");

    [host stop];
    // After a clean stop the path is free — a fresh host can re-bind it.
    MCPUnixSocketServer *third = [[MCPUnixSocketServer alloc] init];
    NSError *e3 = nil;
    [third startWithRequestHandler:StubHandler() error:&e3];
    ok(third.isListening, "election: re-bind succeeds after a clean stop");
    [third stop];

    unsetenv("UDS_SOCKET_PATH");   // caller resets to the functional-test path below
}

// Drain the main dispatch queue / run loop — the client and server post their
// notifications there.
static void Pump(NSTimeInterval seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void test_host_loss(void) {
    // A relay whose host goes away must (a) notice — idle watcher AND mid-request
    // — (b) report it in a form ESEngine can act on (notification, -isConnected,
    // typed error codes), and (c) leave the path free for the next host. This is
    // the transport half of mid-session re-election; the election half is the
    // same -electAndConnect the launch path uses. See
    // design-decisions/mid-session-reelection.md.
    NSString *hlPath = [NSString stringWithFormat:@"/tmp/es-uds-hostloss-%d.sock", getpid()];
    setenv("UDS_SOCKET_PATH", hlPath.fileSystemRepresentation, 1);

    MCPUnixSocketServer *host = [[MCPUnixSocketServer alloc] init];
    NSError *e1 = nil;
    [host startWithRequestHandler:StubHandler() error:&e1];

    __block int disconnects = 0;
    id obs = [NSNotificationCenter.defaultCenter
        addObserverForName:MCPSocketClientHostDisconnectedNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { disconnects++; }];
    __block int idles = 0;
    id idleObs = [NSNotificationCenter.defaultCenter
        addObserverForName:MCPUnixSocketServerDidBecomeIdleNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { idles++; }];

    // (1) Idle client, host stops: the EOF watcher notices.
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@800, @"method":@"ping"}];
    ok(rep != nil && c.isConnected && host.connectionCount == 1,
       "host loss: connected client is counted by the host");
    [host stop];
    Pump(0.5);
    ok(disconnects == 1 && !c.isConnected,
       "host loss (idle): EOF watcher posts the disconnect once, client reports not connected");
    rep = [c sendRequest:@{@"id":@801, @"method":@"x"}];
    ok([rep[@"error"][@"code"] isEqual:@(MCPSocketClientErrorConnectionLost)],
       "host loss (idle): later request returns -32001 ConnectionLost (safe to retry)");
    [c close];
    [c close];
    rep = [c sendRequest:@{@"id":@802, @"method":@"x"}];
    ok([rep[@"error"][@"code"] isEqual:@(MCPSocketClientErrorConnectionLost)],
       "host loss: -close is idempotent and the client stays cleanly dead");

    // (2) The path is free again: a new host binds it and serves a fresh client.
    MCPUnixSocketServer *host2 = [[MCPUnixSocketServer alloc] init];
    NSError *e2 = nil;
    [host2 startWithRequestHandler:StubHandler() error:&e2];
    MCPSocketClient *c2 = [MCPSocketClient connectWithAuthor:nil];
    rep = [c2 sendRequest:@{@"id":@810, @"method":@"ping"}];
    ok(host2.isListening && [rep[@"id"] isEqual:@810],
       "host loss: next host re-binds the same path and a fresh client reaches it");

    // (3) Last peer leaves a live host: the idle notification fires (what a
    //     lingering host waits for), and the count is back to zero.
    [c2 close];
    Pump(0.5);
    ok(idles == 1 && host2.connectionCount == 0,
       "idle: host posts DidBecomeIdle once its last peer closes");

    // (4) Host dies MID-REQUEST. A real MCPUnixSocketServer's -stop is graceful —
    //     a handler already running finishes and its reply goes out before the fd
    //     closes — so to model a host that vanishes (crash, SIGKILL) use a raw
    //     listener that accepts, reads the request, and drops the connection
    //     without answering. The in-flight request must fail with ReplyLost
    //     (outcome unknown — must not be retried), and the disconnect is posted.
    NSString *fakePath = [NSString stringWithFormat:@"/tmp/es-uds-fakehost-%d.sock", getpid()];
    setenv("UDS_SOCKET_PATH", fakePath.fileSystemRepresentation, 1);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un laddr; socklen_t llen = 0;
    ESEngineFillSockaddr(&laddr, &llen, fakePath);
    unlink(fakePath.fileSystemRepresentation);
    bind(lfd, (struct sockaddr *)&laddr, llen);
    listen(lfd, 4);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        int afd = accept(lfd, NULL, NULL);
        char junk[512];
        read(afd, junk, sizeof(junk));   // the request arrives…
        usleep(100 * 1000);
        close(afd);                      // …and the "host" dies without replying
        close(lfd);
    });
    MCPSocketClient *c3 = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *lostRep = [c3 sendRequest:@{@"id":@820, @"method":@"anything"}];
    Pump(0.3);
    ok([lostRep[@"error"][@"code"] isEqual:@(MCPSocketClientErrorReplyLost)] && !c3.isConnected,
       "host loss (mid-request): -32002 ReplyLost, client dead");
    ok(disconnects == 2, "host loss (mid-request): disconnect posted exactly once more");
    ok(idles == 1, "stop: no idle notification from a host that is shutting down");
    [c3 close];
    unlink(fakePath.fileSystemRepresentation);

    [NSNotificationCenter.defaultCenter removeObserver:obs];
    [NSNotificationCenter.defaultCenter removeObserver:idleObs];
    unsetenv("UDS_SOCKET_PATH");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *path = [NSString stringWithFormat:@"/tmp/es-uds-test-%d.sock", getpid()];
        unlink(path.fileSystemRepresentation);

        // Election tests run first (they set/reset UDS_SOCKET_PATH themselves).
        fprintf(stderr, "[election]\n");
        test_election_defer();
        fprintf(stderr, "[host loss]\n");
        test_host_loss();

        // Bring up the functional host on our private path.
        setenv("UDS_SOCKET_PATH", path.fileSystemRepresentation, 1);
        MCPUnixSocketServer *server = [[MCPUnixSocketServer alloc] init];
        NSError *err = nil;
        if (![server startWithRequestHandler:StubHandler() error:&err] || !server.isListening) {
            fprintf(stderr, "FATAL: could not start test host: %s\n", err.localizedDescription.UTF8String);
            return 2;
        }

        fprintf(stderr, "[functional]\n");
        test_roundtrip();
        test_persona();
        test_shared_state();
        test_concurrency();

        fprintf(stderr, "[misbehaving clients]\n");
        test_byte_dribble();
        test_pipelined();
        test_garbage_json();
        test_nonobject_json();
        test_oversized();
        test_slam_shut();
        test_flood();

        fprintf(stderr, "[timeout + shedding]\n");
        test_client_timeout();
        test_shedding();

        [server stop];
        unlink(path.fileSystemRepresentation);

        fprintf(stderr, "\n%d passed, %d failed\n", gPass, gFail);
        return gFail == 0 ? 0 : 1;
    }
}
