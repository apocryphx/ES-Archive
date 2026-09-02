//
//  CDTag.h
//
//
//  Created by Kolja Wawrowsky on 2/28/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "ESUUIDStampedObject.h"

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

@interface CDTag : ESUUIDStampedObject

/// Lookup by name. Case-insensitive. Returns nil if not found.
+ (nullable CDTag *)findByName:(NSString *)name
                       context:(NSManagedObjectContext *)ctx;

/// Find a tag by name, or create it if absent (connect-or-create). A tag the
/// author explicitly names is created on the spot — that's deliberate
/// authorship, distinct from lexical auto-extraction from content, which the
/// archive still does not do. `kind` defaults to "thing" when nil/empty.
/// Returns nil only for an empty name or context.
+ (nullable CDTag *)findOrCreateByName:(NSString *)name
                                  kind:(nullable NSString *)kind
                               context:(NSManagedObjectContext *)ctx;

@end

NS_ASSUME_NONNULL_END

#import "CDTag+CoreDataProperties.h"
