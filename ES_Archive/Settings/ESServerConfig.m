//
//  ESServerConfig.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESServerConfig.h"
#import "CDMemory.h"

const UInt16 ESServerDefaultPort = 59123;

static NSString * const kDefaultsPortMode   = @"ESServerPortMode";
static NSString * const kDefaultsCustomPort = @"ESServerCustomPort";

// Port → author map. NSUserDefaults dictionaries must be plist types with
// string keys, so the map is persisted with stringified port keys
// (e.g. {"59123":"Claude"}) and converted to NSNumber-keyed at the boundary.
static NSString * const kDefaultsPortAuthorMap = @"ESServerPortAuthorMap";

// Claude-bridge switch. Stored as a bool; ABSENT means enabled, so every
// existing and fresh install serves the bridge until it is switched off.
static NSString * const kDefaultsClaudeBridgeEnabled = @"ESClaudeBridgeEnabled";

// Personas declared in Settings that have no archive records yet.
static NSString * const kDefaultsDeclaredAuthors = @"ESDeclaredAuthors";

// Port → JWT-required flag. Same stringified-port persistence; values are
// booleans. Ports absent here inherit the global requireAccessHeader.
static NSString * const kDefaultsPortJWTMap = @"ESServerPortJWTMap";

// Key preserved from the earlier tunnel-listener design so any value the user
// set then survives across this redesign. The semantic is unchanged — "require
// the Cf-Access-Jwt-Assertion header" — only the scope (now whole-server-mode)
// and the public method name (now `requireAccessHeader`) have moved.
static NSString * const kDefaultsRequireAccessHeader = @"ESServerTunnelRequireAccessHeader";

@implementation ESServerConfig

#pragma mark - Port mode

+ (ESServerPortMode)portMode {
    return (ESServerPortMode)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultsPortMode];
}

+ (void)setPortMode:(ESServerPortMode)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kDefaultsPortMode];
}

#pragma mark - Custom port

+ (UInt16)customPort {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultsCustomPort];
    if (stored < 1024 || stored > 65535) return 0;
    return (UInt16)stored;
}

+ (void)setCustomPort:(UInt16)port {
    [[NSUserDefaults standardUserDefaults] setInteger:port forKey:kDefaultsCustomPort];
}

#pragma mark - Effective port

+ (UInt16)effectivePort {
    switch ([self portMode]) {
        case ESServerPortModeCustom: {
            UInt16 p = [self customPort];
            return p > 0 ? p : ESServerDefaultPort;
        }
        case ESServerPortModeDefault:
        default:
            return ESServerDefaultPort;
    }
}

#pragma mark - Port → author map (multi-persona)

+ (NSDictionary<NSNumber *, NSString *> *)portAuthorMap {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDefaultsPortAuthorMap];

    // Convert the stringified-port persistence form back to NSNumber keys,
    // tolerating any non-conforming entries defensively.
    NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
    for (id key in stored) {
        if (![key isKindOfClass:NSString.class]) continue;
        id value = stored[key];
        if (![value isKindOfClass:NSString.class] || [(NSString *)value length] == 0) continue;
        NSInteger port = [(NSString *)key integerValue];
        if (port < 1024 || port > 65535) continue;
        map[@((UInt16)port)] = value;
    }

    // Claude-bridge injection (pure, not written back): while the bridge is
    // enabled its fixed port is always bound — to the stored author if the
    // user picked one, else the default — which also makes the empty-map,
    // zero-config install serve the single Claude listener as before. While
    // disabled, the bridge port is suppressed even if an entry was stored.
    if ([self claudeBridgeEnabled]) {
        if (map[@(ESServerDefaultPort)] == nil) {
            map[@(ESServerDefaultPort)] = [CDMemory defaultAuthor];
        }
    } else {
        [map removeObjectForKey:@(ESServerDefaultPort)];
    }
    return [map copy];
}

+ (void)setPortAuthorMap:(NSDictionary<NSNumber *, NSString *> *)map {
    NSMutableDictionary<NSString *, NSString *> *persisted = [NSMutableDictionary dictionary];
    for (NSNumber *port in map) {
        if (![port isKindOfClass:NSNumber.class]) continue;
        NSString *author = map[port];
        if (![author isKindOfClass:NSString.class] || author.length == 0) continue;
        persisted[port.stringValue] = author;
    }
    [[NSUserDefaults standardUserDefaults] setObject:persisted forKey:kDefaultsPortAuthorMap];
}

+ (NSString *)authorForPort:(UInt16)port {
    return [self portAuthorMap][@(port)];
}

#pragma mark - Claude bridge

+ (BOOL)claudeBridgeEnabled {
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kDefaultsClaudeBridgeEnabled];
    return stored ? stored.boolValue : YES; // enabled by default
}

+ (void)setClaudeBridgeEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDefaultsClaudeBridgeEnabled];
}

#pragma mark - Declared personas

+ (NSArray<NSString *> *)declaredAuthors {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kDefaultsDeclaredAuthors];
    NSMutableArray<NSString *> *authors = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id v in stored) {
        if (![v isKindOfClass:NSString.class] || [(NSString *)v length] == 0) continue;
        if ([seen containsObject:v]) continue;
        [seen addObject:v];
        [authors addObject:v];
    }
    return [authors copy];
}

+ (void)setDeclaredAuthors:(NSArray<NSString *> *)authors {
    NSMutableArray<NSString *> *persisted = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id v in authors) {
        if (![v isKindOfClass:NSString.class] || [(NSString *)v length] == 0) continue;
        if ([seen containsObject:v]) continue;
        [seen addObject:v];
        [persisted addObject:v];
    }
    [[NSUserDefaults standardUserDefaults] setObject:persisted forKey:kDefaultsDeclaredAuthors];
}

#pragma mark - Per-port JWT requirement

+ (NSDictionary<NSNumber *, NSNumber *> *)portJWTMap {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kDefaultsPortJWTMap];
    NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionary];
    for (id key in stored) {
        if (![key isKindOfClass:NSString.class]) continue;
        id value = stored[key];
        if (![value isKindOfClass:NSNumber.class]) continue;
        NSInteger port = [(NSString *)key integerValue];
        if (port < 1024 || port > 65535) continue;
        map[@((UInt16)port)] = @([(NSNumber *)value boolValue]);
    }
    return [map copy];
}

+ (void)setPortJWTMap:(NSDictionary<NSNumber *, NSNumber *> *)map {
    NSMutableDictionary<NSString *, NSNumber *> *persisted = [NSMutableDictionary dictionary];
    for (NSNumber *port in map) {
        if (![port isKindOfClass:NSNumber.class]) continue;
        NSNumber *flag = map[port];
        if (![flag isKindOfClass:NSNumber.class]) continue;
        persisted[port.stringValue] = @(flag.boolValue);
    }
    [[NSUserDefaults standardUserDefaults] setObject:persisted forKey:kDefaultsPortJWTMap];
}

+ (BOOL)requiresJWTForPort:(UInt16)port {
    NSNumber *flag = [self portJWTMap][@(port)];
    if (flag != nil) return flag.boolValue;
    return [self requireAccessHeader]; // inherit the global default
}

#pragma mark - JWT mode

+ (BOOL)requireAccessHeader {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsRequireAccessHeader];
}

+ (void)setRequireAccessHeader:(BOOL)require {
    [[NSUserDefaults standardUserDefaults] setBool:require forKey:kDefaultsRequireAccessHeader];
}

@end
