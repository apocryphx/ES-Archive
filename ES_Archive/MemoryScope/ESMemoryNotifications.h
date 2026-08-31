//
//  ESMemoryNotifications.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

/// Single notification posted by all MCP read/query tools.
extern NSNotificationName const ESMemoryAccessNotification;

/// userInfo keys
extern NSString * const ESMemoryAccessTypeKey;       // NSNumber (ESMemoryAccessType)
extern NSString * const ESMemoryAccessObjectIDsKey;  // NSArray<NSManagedObjectID *>
extern NSString * const ESMemoryAccessScoresKey;     // NSArray<NSNumber *>, nil if not applicable
extern NSString * const ESMemoryAccessOriginIDKey;   // NSManagedObjectID, nil if not applicable

typedef NS_ENUM(NSUInteger, ESMemoryAccessType) {
    ESMemoryAccessTypeRead,
    ESMemoryAccessTypeSearch,
    ESMemoryAccessTypeDiscover,
    ESMemoryAccessTypeRecent,
    ESMemoryAccessTypeTagged,
    ESMemoryAccessTypeLinks,
};
