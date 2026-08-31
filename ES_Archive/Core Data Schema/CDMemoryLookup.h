//
//  CDMemoryLookup.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//
//  Shared title-based disambiguation for CDMemory.
//  Index-based: when ambiguous, matches sorted ascending by dateCreated.
//  Caller picks by index (0 = oldest). includesSubentities = NO to exclude CDMemoryRevision.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CDMemoryLookupStatus) {
    CDMemoryLookupFound,
    CDMemoryLookupAmbiguous,
    CDMemoryLookupNotFound
};

@interface CDMemoryLookupResult : NSObject

@property (nonatomic, readonly) CDMemoryLookupStatus status;
@property (nonatomic, readonly, nullable) CDMemory *memory;
@property (nonatomic, readonly) NSArray<CDMemory *> *matches;

+ (instancetype)found:(CDMemory *)memory;
+ (instancetype)ambiguous:(NSArray<CDMemory *> *)matches;
+ (instancetype)notFound;

@end

@interface CDMemoryLookup : NSObject

/// Resolve a memory by title with optional author/index disambiguation.
/// When ambiguous, matches are sorted ascending by dateCreated (index 0 = oldest).
/// If index is provided, resolves directly from the sorted matches.
///
/// UNSCOPED — internal / maintenance only. Persona-facing tools MUST use the
/// `findScoped…` variants below so a persona cannot resolve another's memory.
+ (CDMemoryLookupResult *)findMemoryWithTitle:(NSString *)title
                                       author:(nullable NSString *)author
                                        index:(nullable NSNumber *)index
                                      context:(NSManagedObjectContext *)ctx;

/// Direct UUID lookup. Returns nil if not found.
///
/// UNSCOPED — internal / maintenance only. Persona-facing tools MUST use
/// `findScopedMemoryWithUUID:scopeAuthor:context:`.
+ (nullable CDMemory *)findMemoryWithUUID:(NSUUID *)uuid
                                  context:(NSManagedObjectContext *)ctx;

#pragma mark - Persona-scoped resolution

/// Scoped title resolution. `scopeAuthor` is an ENFORCED filter (author ==
/// scopeAuthor), not a disambiguator — a title that exists only under another
/// persona resolves to NotFound. `disambiguator` (the tool's explicit `author`
/// arg) narrows WITHIN the silo only; it can never widen it. This is the single
/// resolution gate for all persona-facing lookup tools.
+ (CDMemoryLookupResult *)findScopedMemoryWithTitle:(NSString *)title
                                        scopeAuthor:(NSString *)scopeAuthor
                                      disambiguator:(nullable NSString *)disambiguator
                                              index:(nullable NSNumber *)index
                                            context:(NSManagedObjectContext *)ctx;

/// Scoped UUID resolution — closes the raw-UUID mutation bypass. Fetches by
/// uuid AND author == scopeAuthor in one predicate; a UUID owned by another
/// persona returns nil (no cross-persona existence oracle).
+ (nullable CDMemory *)findScopedMemoryWithUUID:(NSUUID *)uuid
                                    scopeAuthor:(NSString *)scopeAuthor
                                        context:(NSManagedObjectContext *)ctx;

/// Shared ISO8601 formatter.
+ (NSISO8601DateFormatter *)sharedFormatter;

@end

NS_ASSUME_NONNULL_END
