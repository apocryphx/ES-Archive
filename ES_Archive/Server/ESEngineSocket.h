//
//  ESEngineSocket.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  The ONE place the engine socket's location and addressing are decided, shared
//  by both ends so the host and the relay client can never diverge on where the
//  rendezvous lives. Before this existed, MCPSocketClient and MCPUnixSocketServer
//  each resolved the path themselves with *different* fallbacks — the host would
//  advertise on a $HOME path the client never read, silently breaking sharing.
//  See design-decisions/uds-adaptation-from-template.md (adopted from the
//  UDS-Shared-Engine template's UDSProtocol).
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>

NS_ASSUME_NONNULL_BEGIN

/// The App Group both ES Archive bundles declare. Its container is the only
/// filesystem namespace two sandboxed bundles can both reach, so the socket
/// lives there. Both targets MUST use this exact identifier.
extern NSString * const ESEngineAppGroupIdentifier;

/// Leaf filename of the rendezvous socket. Kept short on purpose: the App Group
/// container path is long and sockaddr_un.sun_path caps at ~104 bytes.
extern NSString * const ESEngineSocketFileName;

/// The single resolver both host and client call, so they always agree.
/// Resolution order:
///   1. UDS_SOCKET_PATH env override — an arbitrary (short) path, for tests and
///      tooling that bypass the App Group entirely.
///   2. the App Group container + ESEngineSocketFileName.
///   3. nil — the App Group is unavailable (entitlement missing / not
///      provisioned). Callers treat nil as "cannot share; run the engine
///      in-process". There is deliberately NO $HOME fallback: a path only one
///      side would look for is worse than none.
NSString * _Nullable ESEngineSocketPath(void);

/// Fill a sockaddr_un for `path`. Returns NO (touching nothing the caller relies
/// on) when the path doesn't fit sun_path — the caller's escape hatch is to
/// chdir() into the containing directory and pass just the leaf filename.
/// On success sets *addrLen to SUN_LEN(addr).
BOOL ESEngineFillSockaddr(struct sockaddr_un *addr, socklen_t * _Nullable addrLen, NSString *path);

NS_ASSUME_NONNULL_END
