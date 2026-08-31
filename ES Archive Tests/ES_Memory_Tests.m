//
//  ES_Archive_Tests.m
//  ES Archive Tests
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  XCTest port of the standalone UDS transport harness (Testing/uds-transport).
//  Drives the REAL MCPUnixSocketServer + MCPSocketClient + ESEngineSocket against
//  a private /tmp socket (UDS_SOCKET_PATH override) with a stub handler in place
//  of the Core Data engine — so the suite is hostless (no app launch, never
//  touches the production socket or the CloudKit store) and deterministic.
//
//  The transport .m files are compiled into this bundle via the unity include in
//  ESUDSTransportUnderTest.m — see the note there.
//

#import <XCTest/XCTest.h>
#import "MCPUnixSocketServer.h"
#import "MCPSocketClient.h"
#import "ESEngineSocket.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <stdatomic.h>

#pragma mark - Stub engine (the request handler)

static atomic_int gCounter = 0;
static atomic_bool gShedDidShed = false, gShedDidWork = false;

static NSDictionary *StubReply(id rpcId, NSDictionary *result) {
    if (rpcId == nil) return nil;   // notification
    return @{@"jsonrpc":@"2.0", @"id":rpcId, @"result":result};
}

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
                return nil;
            }
            atomic_store(&gShedDidWork, true);
            return StubReply(rpcId, @{@"worked":@YES});
        }
        if ([method isEqualToString:@"slow"]) {
            if (isClientConnected && !isClientConnected()) return nil;
            usleep(1000 * 1000);   // 1s — outlast a tight client timeout
        }

        int n = atomic_fetch_add(&gCounter, 1) + 1;
        return StubReply(rpcId, @{@"method": method ?: @"(nil)",
                                  @"author": author ?: @"(default)",
                                  @"count": @(n)});
    };
}

#pragma mark - Raw-socket helpers (misbehaving clients)

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
// Reads one '\n'-terminated line; `buf` is caller-owned and preserves bytes past
// the newline (needed for coalesced pipelined replies). Reuse it across reads.
static NSDictionary *RawReadReply(int fd, NSMutableData *buf) {
    uint8_t tmp[4096];
    for (;;) {
        NSRange r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) {
            NSData *line = [buf subdataWithRange:NSMakeRange(0, r.location)];
            [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
            id o = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            return [o isKindOfClass:NSDictionary.class] ? o : nil;
        }
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n <= 0) return nil;
        [buf appendBytes:tmp length:(NSUInteger)n];
    }
}

#pragma mark - Test case

@interface ES_Archive_Tests : XCTestCase
@property (nonatomic, strong) MCPUnixSocketServer *server;
@property (nonatomic, copy)   NSString *sockPath;
@end

@implementation ES_Archive_Tests

// Each test gets a fresh host on a unique /tmp path — isolated, no stale sockets,
// no cross-test coupling. UDS_SOCKET_PATH points both the host and the clients at
// it, so nothing ever reaches the App Group container or the real engine.
- (void)setUp {
    static atomic_int seq = 0;
    atomic_store(&gCounter, 0);
    self.sockPath = [NSString stringWithFormat:@"/tmp/es-uds-xctest-%d-%d.sock",
                     getpid(), atomic_fetch_add(&seq, 1)];
    unlink(self.sockPath.fileSystemRepresentation);
    setenv("UDS_SOCKET_PATH", self.sockPath.fileSystemRepresentation, 1);

    self.server = [[MCPUnixSocketServer alloc] init];
    NSError *e = nil;
    XCTAssertTrue([self.server startWithRequestHandler:StubHandler() error:&e] && self.server.isListening,
                  @"test host should bind and listen: %@", e);
}

- (void)tearDown {
    [self.server stop];
    unlink(self.sockPath.fileSystemRepresentation);
    unsetenv("UDS_SOCKET_PATH");
}

// ── functional ────────────────────────────────────────────────────────────

- (void)testRoundTrip {
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"jsonrpc":@"2.0", @"id":@1, @"method":@"ping"}];
    XCTAssertNotNil(rep);
    XCTAssertEqualObjects(rep[@"id"], @1);
    XCTAssertNotNil(rep[@"result"]);
}

- (void)testPersonaHandshake {
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:@"Isolde"];
    NSDictionary *rep = [c sendRequest:@{@"jsonrpc":@"2.0", @"id":@2, @"method":@"who"}];
    XCTAssertEqualObjects(rep[@"result"][@"author"], @"Isolde",
                          @"author must be scoped per connection from the handshake");
}

- (void)testSharedStateAcrossConnections {
    MCPSocketClient *a = [MCPSocketClient connectWithAuthor:nil];
    MCPSocketClient *b = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *r1 = [a sendRequest:@{@"id":@10, @"method":@"x"}];
    NSDictionary *r2 = [b sendRequest:@{@"id":@11, @"method":@"x"}];
    XCTAssertEqual([r2[@"result"][@"count"] intValue], [r1[@"result"][@"count"] intValue] + 1);
}

- (void)testConcurrencyNoLostWrites {
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
    XCTAssertEqual(atomic_load(&replies), K * M);
    XCTAssertEqual(atomic_load(&gCounter), K * M);
}

// ── misbehaving clients ─────────────────────────────────────────────────────

- (void)testByteDribbleReassembles {
    int fd = RawConnect();
    NSData *d = [@"{\"id\":100,\"method\":\"dribble\"}\n" dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { write(fd, b + i, 1); usleep(200); }
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    XCTAssertEqualObjects(rep[@"id"], @100);
    close(fd);
}

- (void)testPipelinedRequests {
    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":201,\"method\":\"a\"}\n{\"id\":202,\"method\":\"b\"}\n");
    NSMutableData *buf = [NSMutableData data];
    NSDictionary *r1 = RawReadReply(fd, buf);
    NSDictionary *r2 = RawReadReply(fd, buf);
    XCTAssertEqualObjects(r1[@"id"], @201);
    XCTAssertEqualObjects(r2[@"id"], @202);
    close(fd);
}

- (void)testGarbageJSONRejected {
    int fd = RawConnect();
    RawWrite(fd, @"this is not json\n");
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    XCTAssertEqualObjects(rep[@"error"][@"code"], @(-32700));
    close(fd);
}

- (void)testNonObjectJSONRejected {
    int fd = RawConnect();
    RawWrite(fd, @"[1,2,3]\n");
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    XCTAssertEqualObjects(rep[@"error"][@"code"], @(-32700));
    close(fd);
}

- (void)testOversizedValueRoundTrips {
    int fd = RawConnect();
    NSMutableString *big = [NSMutableString stringWithCapacity:200000];
    for (int i = 0; i < 200000; i++) [big appendString:@"x"];
    RawWrite(fd, [NSString stringWithFormat:@"{\"id\":300,\"method\":\"big\",\"blob\":\"%@\"}\n", big]);
    NSDictionary *rep = RawReadReply(fd, [NSMutableData data]);
    XCTAssertEqualObjects(rep[@"id"], @300);
    close(fd);
}

- (void)testSlamShutMidReplyDoesNotKillHost {
    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":400,\"method\":\"slow\"}\n");
    usleep(50 * 1000);
    close(fd);                    // vanish while the host sleeps in "slow"
    usleep(1200 * 1000);          // let the host finish and attempt its write to a dead fd
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@401, @"method":@"after"}];
    XCTAssertNotNil(rep, @"host must survive SIGPIPE and keep serving");
}

- (void)testConnectionFlood {
    for (int i = 0; i < 200; i++) { int fd = RawConnect(); if (fd >= 0) close(fd); }
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    NSDictionary *rep = [c sendRequest:@{@"id":@500, @"method":@"alive"}];
    XCTAssertNotNil(rep, @"host must still accept after a connection storm");
}

// ── timeout + shedding (this branch's additions) ────────────────────────────

- (void)testClientTimeoutReturnsErrorNotHang {
    setenv("UDS_CLIENT_TIMEOUT", "0.3", 1);
    MCPSocketClient *c = [MCPSocketClient connectWithAuthor:nil];
    unsetenv("UDS_CLIENT_TIMEOUT");
    NSDictionary *rep = [c sendRequest:@{@"id":@600, @"method":@"slow"}];
    XCTAssertEqualObjects(rep[@"id"], @600, @"timeout must still answer the id");
    XCTAssertEqualObjects(rep[@"error"][@"code"], @(-32000), @"clean error envelope, not a hang");

    NSDictionary *rep2 = [c sendRequest:@{@"id":@601, @"method":@"x"}];
    XCTAssertNotNil(rep2[@"error"], @"dead connection short-circuits — no stream desync");
}

- (void)testCooperativeSheddingDropsDepartedClient {
    atomic_store(&gShedDidShed, false);
    atomic_store(&gShedDidWork, false);

    int fd = RawConnect();
    RawWrite(fd, @"{\"id\":700,\"method\":\"slowshed\"}\n");
    usleep(80 * 1000);    // let the host read the request and enter the pre-work delay
    close(fd);            // client leaves before the liveness check fires
    usleep(500 * 1000);   // let the handler finish the delay and check liveness
    XCTAssertTrue(atomic_load(&gShedDidShed));
    XCTAssertFalse(atomic_load(&gShedDidWork), @"departed client's request must be shed before work");
}

// ── election (the property the concurrency rework had to preserve) ───────────

- (void)testElectionDefersToLivePeerAndRebinds {
    // A second host on the same live path must defer (probe finds a live peer),
    // never clobber the incumbent that setUp started.
    MCPUnixSocketServer *second = [[MCPUnixSocketServer alloc] init];
    NSError *e = nil;
    BOOL r = [second startWithRequestHandler:StubHandler() error:&e];
    XCTAssertTrue(r);
    XCTAssertFalse(second.isListening, @"second host must defer to the live peer");

    // After the incumbent stops cleanly, a fresh host can re-bind the path.
    [self.server stop];
    MCPUnixSocketServer *third = [[MCPUnixSocketServer alloc] init];
    XCTAssertTrue([third startWithRequestHandler:StubHandler() error:&e] && third.isListening,
                  @"re-bind should succeed after a clean stop");
    [third stop];
}

@end
