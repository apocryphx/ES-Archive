//
//  ESServerConfig.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Centralized access to HTTP server settings (port + JWT mode).
//  All values live in NSUserDefaults. The MCP listener can run in either
//  "Default" mode (full endpoint surface, no auth) or "JWT Required" mode
//  (only POST /mcp, every request must carry a Cf-Access-Jwt-Assertion header).
//  Edge auth in JWT mode is handled by Cloudflare Access; the app holds no
//  secrets.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESServerPortMode) {
    ESServerPortModeDefault   = 0, // 59123
    ESServerPortModeCustom    = 1, // user-entered customPort
};

extern const UInt16 ESServerDefaultPort; // 59123

@interface ESServerConfig : NSObject

+ (ESServerPortMode)portMode;
+ (void)setPortMode:(ESServerPortMode)mode;

+ (UInt16)customPort;
+ (void)setCustomPort:(UInt16)port;

/// The port that should actually be bound, given the current mode.
+ (UInt16)effectivePort;

#pragma mark - Port → author map (multi-persona)

/// The lookup table that maps a listening port to the canonical persona author
/// stamped on (and scoped to) requests arriving on it. This is the runtime
/// persona registry — adding a persona is a row + a bound port, no rebuild.
///
/// The Claude bridge entry is injected on read: while `claudeBridgeEnabled`
/// is YES, the map always contains ESServerDefaultPort (bound to its stored
/// author, falling back to [CDMemory defaultAuthor]); while NO, any stored
/// entry for that port is suppressed. The injection is NOT written back, so
/// a zero-config install serves exactly the single Claude listener on 59123.
///
/// Keys are NSNumber-wrapped UInt16 ports; values are author strings.
+ (NSDictionary<NSNumber *, NSString *> *)portAuthorMap;
+ (void)setPortAuthorMap:(NSDictionary<NSNumber *, NSString *> *)map;

/// The author bound to a given port, or nil if that port has no persona.
/// Callers apply the resolution chain (port-author › defaultAuthor › "AI");
/// nil here is meaningful (unmapped port), not an error.
+ (nullable NSString *)authorForPort:(UInt16)port;

#pragma mark - Claude bridge (fixed port)

/// The local Claude bridge (ES-Memory-Bridge.mcpb) hardcodes
/// ESServerDefaultPort, so its binding is a fixed line, not a table row.
/// While enabled (the default), `portAuthorMap` always carries the bridge
/// entry on that port; while disabled, the port is not bound at all and is
/// unavailable to custom bindings (it stays reserved for the bridge).
+ (BOOL)claudeBridgeEnabled;
+ (void)setClaudeBridgeEnabled:(BOOL)enabled;

#pragma mark - Declared personas (multi-persona)

/// Personas created in Settings that have no records yet. An author with
/// records exists by virtue of the archive; a freshly created one exists only
/// through this list, so it survives without a port binding until its first
/// record lands. Kept tidy by the Personas pane (delete/rename/merge remove
/// or move entries); duplicates and blanks are filtered on read.
+ (NSArray<NSString *> *)declaredAuthors;
+ (void)setDeclaredAuthors:(NSArray<NSString *> *)authors;

#pragma mark - Per-port JWT requirement (multi-persona)

/// Per-port override for the "require Cf-Access-Jwt-Assertion" gate. Keys are
/// NSNumber ports, values are NSNumber booleans. A port absent from this map
/// inherits the global `requireAccessHeader` default, so existing installs are
/// unchanged until a per-port flag is set explicitly.
+ (NSDictionary<NSNumber *, NSNumber *> *)portJWTMap;
+ (void)setPortJWTMap:(NSDictionary<NSNumber *, NSNumber *> *)map;

/// Whether the given port requires the access header. Returns the port's
/// explicit flag when present, otherwise the global `requireAccessHeader`.
+ (BOOL)requiresJWTForPort:(UInt16)port;

#pragma mark - JWT mode (for cloudflared / Cloudflare Access)

/// When YES, the MCP listener registers only POST /mcp (plus 405 stubs) and
/// rejects requests that do not carry a Cf-Access-Jwt-Assertion header.
/// When NO, the full endpoint surface (/mcp, /sse, /messages, /rpc) is
/// registered and no header is required.
/// Defense-in-depth only — full JWT signature verification is not performed
/// in this version; presence is checked.
+ (BOOL)requireAccessHeader;
+ (void)setRequireAccessHeader:(BOOL)require;

@end

NS_ASSUME_NONNULL_END
