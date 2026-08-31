//
//  ESMemoryToolBase.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "ESMemoryNotifications.h"

NS_ASSUME_NONNULL_BEGIN

/// Utility class for MCP memory tools.
/// Owns notification mechanics — tools call postAccessNotification:
/// at result assembly time.
@interface ESMemoryToolBase : NSObject

/// Post ESMemoryAccessNotification with a fully constructed payload.
/// Safe to call from any thread — dispatches to main queue internally.
+ (void)postAccessNotification:(ESMemoryAccessType)type
                     objectIDs:(NSArray<NSManagedObjectID *> *)objectIDs
                        scores:(nullable NSArray<NSNumber *> *)scores
                      originID:(nullable NSManagedObjectID *)originID;

#pragma mark - Persona scoping
//
// The ONE place author scoping is spelled. Every read/list/mutation/pipeline
// path composes `scopePredicateForAuthor:` so a memory is reachable only under
// its own persona. Centralize or it leaks: a scoped search beside an unscoped
// discover is the classic bug. Matching is EXACT (`author == X`) — the
// port→author table holds the one canonical spelling, so exact match is both
// correct and index-friendly.

/// Canonical persona scope predicate: `author == scopeAuthor`. A nil/empty
/// scope returns a never-match predicate (fail-closed) — never an unscoped
/// fetch.
+ (NSPredicate *)scopePredicateForAuthor:(nullable NSString *)scopeAuthor;

/// Like scopePredicateForAuthor: but also excludes type == "fiction". The
/// identity-bearing discover modes use this so invented narratives (e.g. a
/// serial story cycle) can't dominate hubs/lost/forgotten and drown out a
/// persona's real reflective and identity memories. Fiction is surfaced on its
/// own via the dedicated 'fiction' discover mode instead.
+ (NSPredicate *)identityScopeForAuthor:(nullable NSString *)scopeAuthor;

/// Write-stamp author resolution: explicit (tool arg) › scopeAuthor ›
/// +[CDMemory defaultAuthor] › @"AI". Used only on creation/annotation paths
/// (store, comment, attachment). Reads/mutations must use the scope author
/// directly, never the explicit arg, so a caller can't widen its own silo.
+ (NSString *)effectiveAuthorForScope:(nullable NSString *)scopeAuthor
                             explicit:(nullable NSString *)explicitAuthor;

#pragma mark - Argument Coercion Helpers
//
// Boundary coercion for values pulled out of an MCP arguments dictionary.
// JSON-decoded values arrive as id of unknown type — sending an unchecked
// NSNumber-only selector (boolValue / integerValue / unsignedIntegerValue)
// to an NSString crashes with an unrecognized selector. These helpers
// type-check before messaging and fall back to a default. Use them in
// every tool's parameter-resolution block; do not subscript-and-message
// `arguments` directly for typed values.

/// Accepts NSNumber, accepts NSString that parses as integer, else default.
+ (NSInteger)integerFromArgs:(NSDictionary *)args
                          key:(NSString *)key
                      default:(NSInteger)def;

/// Accepts NSNumber, accepts NSString that parses as positive integer, else default.
+ (NSUInteger)unsignedIntegerFromArgs:(NSDictionary *)args
                                   key:(NSString *)key
                               default:(NSUInteger)def;

/// Accepts NSNumber, accepts NSString ("true"/"yes"/"1" → YES, else NO),
/// else default. Never crashes on wrong type.
+ (BOOL)boolFromArgs:(NSDictionary *)args
                  key:(NSString *)key
              default:(BOOL)def;

/// Returns NSString only if value is an NSString with length > 0, else nil.
+ (nullable NSString *)stringFromArgs:(NSDictionary *)args
                                   key:(NSString *)key;

/// Returns NSArray only if value is an NSArray, else nil.
+ (nullable NSArray *)arrayFromArgs:(NSDictionary *)args
                                 key:(NSString *)key;

/// Tag-style normalized array: accepts array of {name,kind} dicts, coerces
/// bare strings into {name:str, kind:"thing"}, also accepts a comma-separated
/// NSString shorthand (each token → {name:token, kind:"thing"}). Drops
/// anything else. Returns possibly-empty NSArray, never nil.
+ (NSArray<NSDictionary *> *)tagArrayFromArgs:(NSDictionary *)args
                                            key:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
