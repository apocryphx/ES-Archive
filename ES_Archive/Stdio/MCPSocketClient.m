//
//  MCPSocketClient.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPSocketClient.h"
#import "ESEngineSocket.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <stdio.h>

NSNotificationName const MCPSocketClientHostDisconnectedNotification =
    @"MCPSocketClientHostDisconnectedNotification";

// A generous default so a legitimately slow reply (a cold embedder is seconds)
// never trips it — only a genuinely wedged or vanished host does. Overridable
// via UDS_CLIENT_TIMEOUT (seconds; <= 0 means wait forever) for tests/tuning.
static NSTimeInterval ESClientTimeout(void) {
    const char *env = getenv("UDS_CLIENT_TIMEOUT");
    if (env && env[0]) return atof(env);
    return 120.0;
}

/// Build the JSON-RPC error envelope we hand back when the relay can't complete
/// a request. Returning THIS instead of nil is the fix for the old failure mode:
/// a dropped/timed-out relay used to return nil, indistinguishable from a
/// notification, so the stdio writer sent nothing and the MCP client hung on that
/// id forever. Notifications (no id) still return nil — there is nothing to answer.
static NSDictionary * _Nullable ESRelayError(id rpcId, NSString *message) {
    if (rpcId == nil) return nil;
    return @{@"jsonrpc":@"2.0", @"id":rpcId,
             @"error":@{@"code":@(-32000), @"message":message}};
}

@implementation MCPSocketClient {
    int               _fd;
    NSLock           *_lock;
    NSTimeInterval    _timeout;
    dispatch_source_t _eofSource;       // fires when the host closes the connection
    BOOL              _disconnectPosted; // guarded by @synchronized(self)
}

+ (nullable instancetype)connectWithAuthor:(nullable NSString *)author {
    NSString *path = ESEngineSocketPath();
    if (!path) return nil;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    if (![self connectFD:fd toPath:path]) {   // no server listening
        close(fd);
        return nil;
    }
    int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    // Non-blocking so reads can be bounded by poll() without ever parking here
    // forever. (connect() above was blocking, which is what we want for it.)
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    MCPSocketClient *c = [self new];
    c->_fd = fd;
    c->_lock = [NSLock new];
    c->_timeout = ESClientTimeout();

    // Declare our persona once, before any request, so the host scopes this
    // whole connection to it. Ordering is guaranteed: the socket delivers this
    // line before the requests that follow.
    if (author.length) {
        NSDictionary *hello = @{@"jsonrpc":@"2.0",
                                @"method":@"$/esarchive/author",
                                @"params":@{@"author":author}};
        NSData *body = [NSJSONSerialization dataWithJSONObject:hello options:0 error:NULL];
        if (body) {
            NSMutableData *line = [body mutableCopy];
            [line appendBytes:"\n" length:1];
            [c writeAll:line];   // best effort; a failure surfaces on the first request
        }
    }

    // Proactively watch for the host closing the connection, even while this relay
    // sits idle between requests — the case the in-request EOF check below can't
    // see. On a real EOF, -hostDisconnected posts a notification so the app exits
    // (a CLI relay has no host to reconnect to). A reply on the wire also makes the
    // fd readable, so the handler PEEKs to tell EOF (recv == 0) from data (> 0).
    __block dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0,
                               dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (src) {
        int watchedFD = fd;
        __weak MCPSocketClient *weakC = c;
        dispatch_source_set_event_handler(src, ^{
            char b;
            ssize_t n = recv(watchedFD, &b, 1, MSG_PEEK | MSG_DONTWAIT);
            if (n > 0) return;   // a reply is on the wire — sendRequest owns it
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
            // n == 0 (peer closed) or a hard error: the host is gone. Cancel first —
            // the fd stays readable-at-EOF, so a level source would re-fire — then notify.
            dispatch_source_cancel(src);
            [weakC hostDisconnected];
        });
        dispatch_source_set_cancel_handler(src, ^{ close(watchedFD); });
        c->_eofSource = src;
        dispatch_resume(src);
    }
    return c;
}

+ (BOOL)connectFD:(int)fd toPath:(NSString *)path {
    struct sockaddr_un addr; socklen_t len = 0;
    if (ESEngineFillSockaddr(&addr, &len, path)) {
        return connect(fd, (struct sockaddr *)&addr, len) == 0;
    }
    // Path too long for sun_path: connect via the leaf relative to the dir.
    NSString *dir  = path.stringByDeletingLastPathComponent;
    NSString *leaf = path.lastPathComponent;
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return NO;
    if (chdir(dir.fileSystemRepresentation) != 0) return NO;
    BOOL ok = NO;
    if (ESEngineFillSockaddr(&addr, &len, leaf)) {
        ok = connect(fd, (struct sockaddr *)&addr, len) == 0;
    }
    chdir(cwd);
    return ok;
}

- (nullable NSDictionary *)sendRequest:(NSDictionary *)rpc {
    id rpcId = rpc[@"id"];
    BOOL isNotification = (rpcId == nil);   // no id => no response expected

    NSData *body = [NSJSONSerialization dataWithJSONObject:rpc options:0 error:NULL];
    if (!body) return ESRelayError(rpcId, @"could not serialize request");
    NSMutableData *line = [body mutableCopy];
    [line appendBytes:"\n" length:1];

    [_lock lock];
    if (_fd < 0) {   // a previous request already found the connection dead
        [_lock unlock];
        return ESRelayError(rpcId, @"shared engine connection is closed");
    }
    if (![self writeAll:line]) {
        [self closeConnection];
        [self hostDisconnected];   // the host is gone — the relay should exit
        [_lock unlock];
        return ESRelayError(rpcId, @"shared engine connection lost while sending");
    }
    if (isNotification) { [_lock unlock]; return nil; }

    BOOL timedOut = NO;
    NSDictionary *reply = [self readReplyTimedOut:&timedOut];
    if (!reply) {
        // Timed out or the host vanished mid-reply. Either way the connection is
        // now unusable — a late reply arriving later would desync the stream — so
        // close it. Subsequent requests short-circuit to a clean error above until
        // the session restarts and re-elects. (Mid-session reconnect is future
        // work; see design-decisions/uds-adaptation-from-template.md.)
        [self closeConnection];
        if (!timedOut) [self hostDisconnected];   // EOF (not a slow host) — exit
        [_lock unlock];
        return ESRelayError(rpcId, timedOut
            ? [NSString stringWithFormat:@"no reply from shared engine within %.0fs; connection closed", _timeout]
            : @"shared engine connection lost");
    }
    [_lock unlock];
    return reply;
}

/// Read one newline-delimited reply, bounded by _timeout. Returns the decoded
/// dictionary, or nil (with *timedOut set) on deadline / EOF / error. Caller
/// holds _lock. Poll gates every read, so a zero/infinite timeout never busy-waits.
- (nullable NSDictionary *)readReplyTimedOut:(BOOL *)timedOut {
    NSDate *deadline = _timeout > 0 ? [NSDate dateWithTimeIntervalSinceNow:_timeout] : nil;
    NSMutableData *buf = [NSMutableData data];
    NSData *nl = [NSData dataWithBytes:"\n" length:1];
    uint8_t tmp[8192];

    for (;;) {
        NSRange r = [buf rangeOfData:nl options:0 range:NSMakeRange(0, buf.length)];
        if (r.location != NSNotFound) {
            NSData *lineData = [buf subdataWithRange:NSMakeRange(0, r.location)];
            id obj = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
            return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        }

        int ms;
        if (deadline) {
            NSTimeInterval rem = deadline.timeIntervalSinceNow;
            if (rem <= 0) { *timedOut = YES; return nil; }
            ms = (int)(rem * 1000.0) + 1;
        } else {
            ms = -1;   // wait forever, but still via poll (no busy-wait)
        }
        struct pollfd p = { .fd = _fd, .events = POLLIN };
        int pr = poll(&p, 1, ms);
        if (pr == 0) { *timedOut = YES; return nil; }
        if (pr < 0) { if (errno == EINTR) continue; return nil; }

        ssize_t n = read(_fd, tmp, sizeof(tmp));
        if (n > 0) { [buf appendBytes:tmp length:(NSUInteger)n]; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;  // spurious wake; re-poll
        return nil;   // n == 0 (host gone) or a real error
    }
}

/// Write the whole buffer. Non-blocking fd, so EAGAIN → poll(POLLOUT). Caller
/// holds _lock (or is the connect path, before the object is shared).
- (BOOL)writeAll:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t n = write(_fd, bytes, remaining);
        if (n > 0) { bytes += n; remaining -= (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd p = { .fd = _fd, .events = POLLOUT };
            if (poll(&p, 1, 2000) <= 0) return NO;
            continue;
        }
        return NO;   // EPIPE or similar
    }
    return YES;
}

- (void)closeConnection {
    if (_eofSource) {
        dispatch_source_cancel(_eofSource);   // its cancel handler owns the fd close
        _eofSource = nil;
    } else if (_fd >= 0) {
        close(_fd);
    }
    _fd = -1;
}

/// The host went away — from the idle EOF watcher, or an EOF hit mid-request. Post
/// once, on the main queue, so ESStdioAppDelegate can terminate the relay. A slow
/// host (a timeout) is NOT a disconnect and must not call this. Idempotent.
- (void)hostDisconnected {
    @synchronized (self) {
        if (_disconnectPosted) return;
        _disconnectPosted = YES;
    }
    fprintf(stderr, "[es-archive-mcp] shared engine host disconnected — relay should exit\n");
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:MCPSocketClientHostDisconnectedNotification object:self];
    });
}

- (void)dealloc {
    if (_eofSource) { dispatch_source_cancel(_eofSource); _eofSource = nil; }
    else if (_fd >= 0) { close(_fd); }
}

@end
