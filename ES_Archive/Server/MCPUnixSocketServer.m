//
//  MCPUnixSocketServer.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Concurrency model (three GCD roles, adopted from the UDS-Shared-Engine
//  template — see design-decisions/uds-adaptation-from-template.md):
//    * accept   — a serial source on the listen fd; drains a whole connection
//                 burst (accept until EWOULDBLOCK) and re-arms.
//    * conns    — a concurrent queue hosting one read source per connection;
//                 idle connections cost ~0 threads, a closed peer cancels its
//                 source and frees the fd at once.
//    * engine   — the handler funnels to the main queue (the Core Data view
//                 context), which is the single writer.
//  The point of the split over the previous single serial queue: a slow engine
//  call (a cold embedder is seconds) no longer blocks accept() or other peers'
//  reads — it only serializes engine work, which was always main-bound anyway.
//

#import "MCPUnixSocketServer.h"
#import "ESEngineSocket.h"
#import "ESLog.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>

NSString * const MCPUnixAuthorHandshakeMethod = @"$/esarchive/author";

@implementation MCPUnixSocketServer {
    NSString             *_socketPath;
    int                   _listenFD;
    BOOL                  _listening;
    dispatch_queue_t      _acceptQ;         // serial: accept() events
    dispatch_queue_t      _connQ;           // concurrent: per-connection read sources
    dispatch_source_t     _acceptSource;
    NSMutableSet<dispatch_source_t> *_connSources;  // @synchronized(_connSources)
    MCPUnixRequestHandler _handler;
}

+ (instancetype)sharedInstance {
    static MCPUnixSocketServer *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _acceptQ = dispatch_queue_create("com.elarity.es-archive.uds.accept", DISPATCH_QUEUE_SERIAL);
        _connQ   = dispatch_queue_create("com.elarity.es-archive.uds.conns", DISPATCH_QUEUE_CONCURRENT);
        _connSources = [NSMutableSet set];
        signal(SIGPIPE, SIG_IGN);
    }
    return self;
}

- (NSString *)socketPath { return _socketPath; }
- (BOOL)isListening { return _listening; }

#pragma mark - Addressing helpers (chdir fallback for over-long App Group paths)

/// bind() `fd` to `path`, transparently falling back to a chdir + relative-leaf
/// bind when the absolute path overflows sun_path (~104 bytes — the App Group
/// container path can approach it). Returns 0 on success, else the failing errno
/// (so the caller can distinguish EADDRINUSE from a hard error).
static int ESBindSocket(int fd, NSString *path) {
    struct sockaddr_un addr; socklen_t len = 0;
    if (ESEngineFillSockaddr(&addr, &len, path)) {
        return bind(fd, (struct sockaddr *)&addr, len) == 0 ? 0 : errno;
    }
    NSString *dir  = path.stringByDeletingLastPathComponent;
    NSString *leaf = path.lastPathComponent;
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return errno;
    if (chdir(dir.fileSystemRepresentation) != 0) return errno;
    int result = ENAMETOOLONG;
    if (ESEngineFillSockaddr(&addr, &len, leaf)) {
        result = bind(fd, (struct sockaddr *)&addr, len) == 0 ? 0 : errno;
    }
    chdir(cwd); // restore, so the rest of the process is unaffected
    return result;
}

/// Is a LIVE host accepting on `path`? A successful connect() proves someone is
/// blocked in accept() — it cannot succeed against a crashed owner's corpse.
static BOOL ESProbeSocket(NSString *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_un addr; socklen_t len = 0;
    BOOL alive = NO;
    if (ESEngineFillSockaddr(&addr, &len, path)) {
        alive = connect(fd, (struct sockaddr *)&addr, len) == 0;
    } else {
        NSString *dir  = path.stringByDeletingLastPathComponent;
        NSString *leaf = path.lastPathComponent;
        char cwd[PATH_MAX];
        if (getcwd(cwd, sizeof(cwd)) && chdir(dir.fileSystemRepresentation) == 0) {
            if (ESEngineFillSockaddr(&addr, &len, leaf)) {
                alive = connect(fd, (struct sockaddr *)&addr, len) == 0;
            }
            chdir(cwd);
        }
    }
    close(fd);
    return alive;
}

/// Cooperative-shedding liveness probe: PEEK the read side (non-destructive) —
/// recv returns 0 exactly when the peer has closed. We never WRITE a probe byte:
/// on a stream protocol that would corrupt the client's data.
static BOOL ESPeerIsConnected(int fd) {
    char b;
    ssize_t n = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    if (n == 0) return NO;                                        // EOF: peer closed
    if (n < 0) return (errno == EAGAIN || errno == EWOULDBLOCK);  // open-but-idle vs. error
    return YES;                                                   // >0: a pipelined byte waits
}

#pragma mark - Election + serve

- (BOOL)startWithRequestHandler:(MCPUnixRequestHandler)handler error:(NSError **)error {
    if (_listening) return YES;
    _handler = [handler copy];
    return [self runElectionAndAccept:YES error:error];
}

- (BOOL)electAsHostWithError:(NSError **)error {
    if (_listening) return YES;
    return [self runElectionAndAccept:NO error:error];
}

- (void)serveWithRequestHandler:(MCPUnixRequestHandler)handler {
    // Only a bound host that hasn't already started its accept source may begin
    // serving; a relay or a not-yet-elected process is a no-op.
    if (!_listening || _acceptSource) return;
    _handler = [handler copy];
    [self startAccepting];
    ESLog(@"[MCP-UDS] serving peers (pid %d) at %@", getpid(), _socketPath);
}

/// The bind()-exclusivity election, shared by the one-shot path
/// (-startWithRequestHandler:, `beginAccepting == YES`) and the two-phase path
/// (-electAsHostWithError: + -serveWithRequestHandler:, `beginAccepting == NO`).
/// On winning the bind it listens; it starts accepting immediately only for the
/// one-shot path, whose handler is already set. The bind IS the election — never a
/// check-then-act (see socket-election.md).
- (BOOL)runElectionAndAccept:(BOOL)beginAccepting error:(NSError **)error {
    // One resolver, shared with MCPSocketClient, so host and client never diverge.
    _socketPath = ESEngineSocketPath();
    if (!_socketPath) {
        if (error) *error = [NSError errorWithDomain:@"MCPUnixSocketServer" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"App Group container unavailable — cannot host the shared engine."}];
        return NO;   // caller (ESEngine) degrades to an in-process engine.
    }

    // On EADDRINUSE, connect-probe: a live peer owns it (defer, don't serve); a
    // refused connect => stale socket, unlink + retry.
    const char *cpath = _socketPath.fileSystemRepresentation;
    for (int attempt = 0; attempt < 4; attempt++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
        int be = ESBindSocket(fd, _socketPath);
        if (be == 0) {
            // Non-blocking listen socket so the accept source can drain a whole
            // burst and re-arm; SOMAXCONN backlog absorbs connection storms
            // (connection-per-request clients make bursts the normal case) — and,
            // on the two-phase path, holds peers that connect while the host is
            // loading its engine, until -serveWithRequestHandler: starts accepting.
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            listen(fd, SOMAXCONN);
            _listenFD = fd;
            _listening = YES;
            if (beginAccepting) [self startAccepting];
            ESLog(@"[MCP-UDS] hosting (pid %d) at %@%@", getpid(), _socketPath,
                  beginAccepting ? @"" : @" — accept deferred until the engine is ready");
            return YES;
        }
        close(fd);
        if (be == EADDRINUSE) {
            if (ESProbeSocket(_socketPath)) {
                ESLog(@"[MCP-UDS] a live peer already hosts the socket; deferring");
                return YES;               // not listening; caller connects as a client
            }
            ESLog(@"[MCP-UDS] removing stale socket, re-binding");
            unlink(cpath);
            continue;
        }
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:be userInfo:nil];
        return NO;
    }
    return NO;
}

- (void)stop {
    if (!_listening) return;
    _listening = NO;
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    // Cancel every live connection (each cancel handler closes its fd and drops
    // itself from the set). dispatch_source_cancel is safe from any thread, so no
    // cross-queue barrier is needed — which also removes the old shutdown deadlock
    // window (main-thread stop vs. an in-flight handler blocked on the main queue).
    NSArray<dispatch_source_t> *sources;
    @synchronized (_connSources) { sources = _connSources.allObjects; }
    for (dispatch_source_t s in sources) dispatch_source_cancel(s);
    if (_listenFD >= 0) { close(_listenFD); _listenFD = -1; }
    unlink(_socketPath.fileSystemRepresentation);
    ESLog(@"[MCP-UDS] stopped");
}

#pragma mark - Accept

- (void)startAccepting {
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenFD, 0, _acceptQ);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_acceptSource, ^{ [ws acceptPending]; });
    dispatch_resume(_acceptSource);
}

- (void)acceptPending {
    for (;;) {
        int cfd = accept(_listenFD, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;   // transient
            break;                                                   // EWOULDBLOCK: drained
        }
        int on = 1; setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        int flags = fcntl(cfd, F_GETFL, 0);
        fcntl(cfd, F_SETFL, flags | O_NONBLOCK);
        [self serveConnection:cfd];
    }
}

#pragma mark - Per-connection read loop

- (void)serveConnection:(int)cfd {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, cfd, 0, _connQ);
    NSMutableData *buf = [NSMutableData data];
    __block NSString *connAuthor = nil;         // per-connection persona (from handshake)
    MCPUnixRequestHandler handler = _handler;   // captured by value; set once at start
    __weak typeof(self) ws = self;

    dispatch_source_set_event_handler(src, ^{
        uint8_t tmp[16384];
        for (;;) {
            ssize_t n = read(cfd, tmp, sizeof(tmp));
            if (n > 0) {
                [buf appendBytes:tmp length:(NSUInteger)n];
                NSData *nl = [NSData dataWithBytes:"\n" length:1];
                NSRange r;
                while ((r = [buf rangeOfData:nl options:0 range:NSMakeRange(0, buf.length)]).location != NSNotFound) {
                    NSData *lineData = [buf subdataWithRange:NSMakeRange(0, r.location)];
                    [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
                    if (lineData.length == 0) continue;

                    __strong typeof(ws) ss = ws;
                    if (!ss) return;

                    id obj = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
                    if (![obj isKindOfClass:NSDictionary.class]) {
                        NSData *e = [ss encode:@{@"jsonrpc":@"2.0", @"id":[NSNull null],
                            @"error":@{@"code":@(-32700), @"message":@"Parse error"}}];
                        if (e) [ss writeAll:e toFD:cfd];
                        continue;
                    }
                    NSDictionary *json = obj;

                    // Author handshake: set this connection's persona, don't dispatch.
                    if ([json[@"method"] isEqual:MCPUnixAuthorHandshakeMethod]) {
                        id a = json[@"params"][@"author"];
                        connAuthor = [a isKindOfClass:NSString.class] ? a : nil;
                        ESLog(@"[MCP-UDS] connection persona: %@", connAuthor ? : @"(default)");
                        continue;
                    }

                    // Hand the request to the engine with a shedding predicate that
                    // peeks THIS connection's read side at dispatch time.
                    NSDictionary *envelope = handler
                        ? handler(json, connAuthor, ^BOOL{ return ESPeerIsConnected(cfd); })
                        : nil;
                    if (envelope) {
                        NSData *reply = [ss encode:envelope];
                        if (reply) [ss writeAll:reply toFD:cfd];
                    }
                }
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;  // drained; wait for more
            if (n < 0 && errno == EINTR) continue;
            dispatch_source_cancel(src);   // 0 = peer closed, or a real error
            return;
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(cfd);
        @synchronized (self->_connSources) { [self->_connSources removeObject:src]; }
    });
    @synchronized (_connSources) { [_connSources addObject:src]; }
    dispatch_resume(src);
}

/// write() can return short or, on our non-blocking sockets, EAGAIN; loop until
/// the whole reply is out or the peer dies. A single write() risked truncating a
/// large reply (search results, tool schemas) into a corrupt JSON frame.
- (void)writeAll:(NSData *)data toFD:(int)fd {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t n = write(fd, bytes, remaining);
        if (n > 0) { bytes += n; remaining -= (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd p = { .fd = fd, .events = POLLOUT };
            if (poll(&p, 1, 2000) <= 0) break;   // give a stuck reader up to 2s
            continue;
        }
        break;   // EPIPE or similar: peer gone
    }
}

- (NSData *)encode:(NSDictionary *)dict {
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:NULL];
    NSMutableData *out = [d mutableCopy];
    [out appendBytes:"\n" length:1];
    return out;
}

@end
