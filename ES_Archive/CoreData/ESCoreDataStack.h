//
//  ESCoreDataStack.h
//  ES Archive
//
//  Singleton wrapper for NSPersistentCloudKitContainer.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the persistent store fails to load. `userInfo[@"message"]`
/// is a human-readable NSString describing the failure (suitable for the
/// System Pulse log pane).
extern NSNotificationName const ESCoreDataStackErrorNotification;

/// Runs a block synchronously on the main thread and returns its result.
/// If already on the main thread, the block executes immediately.
/// Use this for all Core Data viewContext access from background threads.
FOUNDATION_EXTERN id _Nullable ExecuteOnMainThread(id _Nullable (^block)(void));

@interface ESCoreDataStack : NSObject

@property (class, readonly, strong) ESCoreDataStack *shared;
@property (readonly, strong) NSPersistentCloudKitContainer *persistentContainer;
@property (readonly, strong) NSManagedObjectContext *viewContext;

- (void)saveContext;
- (void)resetPersistentContainer;
- (void)triggerCloudKitSync;
- (void)startObservingCloudKitEvents;
- (void)stopObservingCloudKitEvents;

@end

NS_ASSUME_NONNULL_END
