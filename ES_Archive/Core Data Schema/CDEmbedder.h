//
//  CDEmbedder+CoreDataClass.h
//  ES Archive MCP
//
//  Created by Kolja Wawrowsky on 5/6/26.
//
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDVector;

NS_ASSUME_NONNULL_BEGIN

@interface CDEmbedder : NSManagedObject

#pragma mark - Lookup

/// Find an existing CDEmbedder with the given identifier, or create one
/// initialized with the given dimension. The identifier is the unique merge
/// key; matching is case-sensitive String equality.
///
/// If an existing row is found with a vectorDimension that differs from the
/// requested dimension, this is logged as a warning but the existing row is
/// returned — the database is the authoritative source for stored vectors,
/// and a runtime/storage mismatch suggests something has changed under the
/// hood (model swap without identifier bump?) and re-embedding is needed.
+ (nullable CDEmbedder *)findOrCreateWithIdentifier:(NSString *)identifier
                                          dimension:(NSUInteger)dimension
                                          inContext:(NSManagedObjectContext *)context;

#pragma mark - Lifecycle

/// Update dateLastUsed to now. Throttled to once-per-minute granularity to
/// avoid write churn on encode-heavy paths. Caller must save the context.
- (void)touchDateLastUsed;

/// Update dateLastActivated to now. NOT throttled — every call writes.
/// This is the authored-preference signal: only touched on deliberate
/// activation events (archive_maintenance(embedder:), first-launch
/// migration from legacy NSUserDefaults, fallback activation on empty
/// corpus). Differs from dateLastUsed (telemetry, every encode) — the
/// active embedder for the archive is the CDEmbedder with the most
/// recent dateLastActivated. Caller must save the context.
- (void)touchDateLastActivated;

@end

NS_ASSUME_NONNULL_END

#import "CDEmbedder+CoreDataProperties.h"
