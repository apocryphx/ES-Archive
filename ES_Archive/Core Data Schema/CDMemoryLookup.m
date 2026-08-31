//
//  CDMemoryLookup.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Index-based disambiguation. Matches ordered by: dateCreated ascending
//  (0 = oldest), then — for copies sharing a timestamp — larger body first,
//  then objectID as a final tiebreak. The order must be TOTAL and stable so
//  that the index in an ambiguous response resolves to the same row on a
//  later read or erase; dateCreated alone leaves same-instant duplicates in
//  an undefined Core Data fetch order, which could point index N at a
//  different row between calls.
//

#import "CDMemoryLookup.h"
#import "CDMemory.h"
#import "ESMemoryToolBase.h" // single source of the persona scope predicate

// Total, stable ordering of same-title matches. Sorted in memory (not via
// NSSortDescriptor) because body length is not a stored Core Data attribute
// and the match set is tiny. Primary: oldest first. Tiebreak on equal
// timestamps: larger body first (the fuller record becomes index 0). Final
// tiebreak on identical timestamp+size: the permanent objectID URI, so the
// order is fully deterministic across calls.
static NSArray<CDMemory *> *ESDisambiguationOrder(NSArray<CDMemory *> *matches) {
    return [matches sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
        NSDate *da = a.dateCreated ?: NSDate.distantPast;
        NSDate *db = b.dateCreated ?: NSDate.distantPast;
        NSComparisonResult r = [da compare:db];
        if (r != NSOrderedSame) return r;

        NSUInteger la = a.body.length, lb = b.body.length;
        if (la != lb) return la > lb ? NSOrderedAscending : NSOrderedDescending;

        return [a.objectID.URIRepresentation.absoluteString
                compare:b.objectID.URIRepresentation.absoluteString];
    }];
}

#pragma mark - CDMemoryLookupResult

@interface CDMemoryLookupResult ()
@property (nonatomic, readwrite) CDMemoryLookupStatus status;
@property (nonatomic, readwrite, nullable) CDMemory *memory;
@property (nonatomic, readwrite) NSArray<CDMemory *> *matches;
@end

@implementation CDMemoryLookupResult

+ (instancetype)found:(CDMemory *)memory {
    CDMemoryLookupResult *r = [CDMemoryLookupResult new];
    r.status = CDMemoryLookupFound;
    r.memory = memory;
    r.matches = @[memory];
    return r;
}

+ (instancetype)ambiguous:(NSArray<CDMemory *> *)matches {
    CDMemoryLookupResult *r = [CDMemoryLookupResult new];
    r.status = CDMemoryLookupAmbiguous;
    r.memory = nil;
    r.matches = matches;
    return r;
}

+ (instancetype)notFound {
    CDMemoryLookupResult *r = [CDMemoryLookupResult new];
    r.status = CDMemoryLookupNotFound;
    r.memory = nil;
    r.matches = @[];
    return r;
}

@end

#pragma mark - CDMemoryLookup

@implementation CDMemoryLookup

+ (NSISO8601DateFormatter *)sharedFormatter {
    static NSISO8601DateFormatter *fmt;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [NSISO8601DateFormatter new];
        fmt.formatOptions = NSISO8601DateFormatWithInternetDateTime
                          | NSISO8601DateFormatWithFractionalSeconds;
    });
    return fmt;
}

+ (CDMemoryLookupResult *)findMemoryWithTitle:(NSString *)title
                                       author:(NSString *)author
                                        index:(NSNumber *)index
                                      context:(NSManagedObjectContext *)ctx {

    if (!ctx) {
        NSLog(@"CDMemoryLookup: nil context");
        return [CDMemoryLookupResult notFound];
    }
    if (!title || title.length == 0) {
        return [CDMemoryLookupResult notFound];
    }

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO; // Exclude CDMemoryRevision
    NSMutableArray *preds = [NSMutableArray array];

    // Title (case/diacritic insensitive)
    [preds addObject:[NSPredicate predicateWithFormat:@"title ==[cd] %@", title]];

    // Optional author
    if (author.length > 0) {
        [preds addObject:[NSPredicate predicateWithFormat:@"author ==[cd] %@", author]];
    }

    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:preds];

    NSError *error = nil;
    NSArray<CDMemory *> *results = [ctx executeFetchRequest:fetch error:&error];
    if (error) {
        NSLog(@"CDMemoryLookup database error: %@", error);
        return [CDMemoryLookupResult notFound];
    }
    results = ESDisambiguationOrder(results);  // total, stable order for indexing

    if (results.count == 0) {
        return [CDMemoryLookupResult notFound];
    } else if (results.count == 1) {
        return [CDMemoryLookupResult found:results.firstObject];
    } else {
        // Multiple matches — resolve by index if provided
        if (index != nil) {
            NSInteger idx = index.integerValue;
            if (idx >= 0 && idx < (NSInteger)results.count) {
                return [CDMemoryLookupResult found:results[idx]];
            }
            return [CDMemoryLookupResult notFound];
        }
        return [CDMemoryLookupResult ambiguous:results];
    }
}

+ (CDMemory *)findMemoryWithUUID:(NSUUID *)uuid context:(NSManagedObjectContext *)ctx {
    if (!uuid || !ctx) return nil;
    NSFetchRequest *fetch = [CDMemory fetchRequest];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
    fetch.fetchLimit = 1;
    NSError *error = nil;
    NSArray *results = [ctx executeFetchRequest:fetch error:&error];
    if (error) {
        NSLog(@"CDMemoryLookup UUID error: %@", error);
        return nil;
    }
    return results.firstObject;
}

#pragma mark - Persona-scoped resolution

+ (CDMemoryLookupResult *)findScopedMemoryWithTitle:(NSString *)title
                                        scopeAuthor:(NSString *)scopeAuthor
                                      disambiguator:(NSString *)disambiguator
                                              index:(NSNumber *)index
                                            context:(NSManagedObjectContext *)ctx {
    if (!ctx) {
        NSLog(@"CDMemoryLookup: nil context");
        return [CDMemoryLookupResult notFound];
    }
    if (!title || title.length == 0) {
        return [CDMemoryLookupResult notFound];
    }

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO; // Exclude CDMemoryRevision
    NSMutableArray *preds = [NSMutableArray array];

    // Title (case/diacritic insensitive).
    [preds addObject:[NSPredicate predicateWithFormat:@"title ==[cd] %@", title]];

    // Enforced persona scope (fail-closed on nil/empty scope).
    [preds addObject:[ESMemoryToolBase scopePredicateForAuthor:scopeAuthor]];

    // Within-silo disambiguation only. Never widens the silo.
    if (disambiguator.length > 0) {
        [preds addObject:[NSPredicate predicateWithFormat:@"author ==[cd] %@", disambiguator]];
    }

    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:preds];

    NSError *error = nil;
    NSArray<CDMemory *> *results = [ctx executeFetchRequest:fetch error:&error];
    if (error) {
        NSLog(@"CDMemoryLookup database error: %@", error);
        return [CDMemoryLookupResult notFound];
    }
    results = ESDisambiguationOrder(results);  // total, stable order for indexing

    if (results.count == 0) {
        return [CDMemoryLookupResult notFound];
    } else if (results.count == 1) {
        return [CDMemoryLookupResult found:results.firstObject];
    } else {
        if (index != nil) {
            NSInteger idx = index.integerValue;
            if (idx >= 0 && idx < (NSInteger)results.count) {
                return [CDMemoryLookupResult found:results[idx]];
            }
            return [CDMemoryLookupResult notFound];
        }
        return [CDMemoryLookupResult ambiguous:results];
    }
}

+ (CDMemory *)findScopedMemoryWithUUID:(NSUUID *)uuid
                           scopeAuthor:(NSString *)scopeAuthor
                               context:(NSManagedObjectContext *)ctx {
    if (!uuid || !ctx) return nil;
    NSFetchRequest *fetch = [CDMemory fetchRequest];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        [NSPredicate predicateWithFormat:@"uuid == %@", uuid],
        [ESMemoryToolBase scopePredicateForAuthor:scopeAuthor],
    ]];
    fetch.fetchLimit = 1;
    NSError *error = nil;
    NSArray *results = [ctx executeFetchRequest:fetch error:&error];
    if (error) {
        NSLog(@"CDMemoryLookup UUID error: %@", error);
        return nil;
    }
    return results.firstObject;
}

@end
