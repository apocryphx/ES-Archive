//
//  ESEngineSocket.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESEngineSocket.h"
#import <string.h>

// The group id must match the `com.apple.security.application-groups`
// entitlement in BOTH ES-Memory.entitlements and ES-Memory-Server.entitlements.
NSString * const ESEngineAppGroupIdentifier = @"group.com.elarity.es-archive";
NSString * const ESEngineSocketFileName     = @"es-archive-engine.sock";

NSString * _Nullable ESEngineSocketPath(void) {
    // Test / tooling override: point both host and client at an arbitrary path
    // (e.g. a short /tmp socket in the transport harness), bypassing the App
    // Group entirely. Both sides read the same env, so they still agree.
    const char *override = getenv("UDS_SOCKET_PATH");
    if (override && override[0]) {
        return [NSFileManager.defaultManager stringWithFileSystemRepresentation:override
                                                                         length:strlen(override)];
    }

    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:ESEngineAppGroupIdentifier];
    if (!container) {
        return nil; // App Group entitlement missing / not provisioned.
    }
    return [[container URLByAppendingPathComponent:ESEngineSocketFileName] path];
}

BOOL ESEngineFillSockaddr(struct sockaddr_un *addr, socklen_t *addrLen, NSString *path) {
    const char *cpath = path.fileSystemRepresentation;
    // sun_path must hold the string AND a NUL terminator.
    if (!cpath || strlen(cpath) >= sizeof(addr->sun_path)) {
        return NO;
    }
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    strlcpy(addr->sun_path, cpath, sizeof(addr->sun_path));
    if (addrLen) {
        *addrLen = (socklen_t)SUN_LEN(addr);
    }
    return YES;
}
