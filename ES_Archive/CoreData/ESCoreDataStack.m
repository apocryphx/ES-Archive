//
//  ESCoreDataStack.m
//  ES Archive
//
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESCoreDataStack.h"
#import "ESLog.h"
#import <CloudKit/CloudKit.h>

NSNotificationName const ESCoreDataStackErrorNotification = @"ESCoreDataStackError";

static void ESPostCoreDataStackError(NSString *message) {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ESCoreDataStackErrorNotification
                          object:nil
                        userInfo:@{ @"message": message }];
    });
}

#pragma mark - Main Thread Helper

id _Nullable ExecuteOnMainThread(id _Nullable (^block)(void)) {
    if ([NSThread isMainThread]) {
        return block();
    } else {
        __block id result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = block();
        });
        return result;
    }
}

@implementation ESCoreDataStack {
    id _cloudKitEventObserver;
}

@synthesize persistentContainer = _persistentContainer;

#pragma mark - Singleton

+ (ESCoreDataStack *)shared {
    static ESCoreDataStack *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ESCoreDataStack alloc] init];
        [instance startObservingCloudKitEvents];
    });
    return instance;
}

#pragma mark - Core Data Stack

- (NSPersistentCloudKitContainer *)persistentContainer {
    @synchronized (self) {
        if (_persistentContainer == nil) {
            _persistentContainer = [[NSPersistentCloudKitContainer alloc] initWithName:@"Electric_Sheep"];
            
            // Must be set BEFORE loading stores
            NSPersistentStoreDescription *desc = _persistentContainer.persistentStoreDescriptions.firstObject;
            [desc setOption:@YES forKey:NSPersistentHistoryTrackingKey];
            [desc setOption:@YES forKey:NSPersistentStoreRemoteChangeNotificationPostOptionKey];
            
            [_persistentContainer loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *storeDescription, NSError *error) {
                if (error != nil) {
                    NSLog(@"NSPersistentCloudKitContainer error %@, %@", error, error.userInfo);
                    NSString *url = storeDescription.URL.path ?: @"(no url)";
                    NSString *msg = [NSString stringWithFormat:
                        @"Core Data load failed: %@ (code %ld, domain %@) — store: %@",
                        error.localizedDescription, (long)error.code, error.domain, url];
                    ESPostCoreDataStackError(msg);
                    if (error.userInfo.count > 0) {
                        ESPostCoreDataStackError([NSString stringWithFormat:@"userInfo: %@", error.userInfo]);
                    }
                    return;
                }
                [NSOperationQueue.mainQueue addOperationWithBlock:^{
                    NSManagedObjectContext *context = self->_persistentContainer.viewContext;
                    context.automaticallyMergesChangesFromParent = YES;
                    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
                    context.undoManager = NSUndoManager.new;
                }];
            }];
        }
    }
    return _persistentContainer;
}

- (NSManagedObjectContext *)viewContext {
    return self.persistentContainer.viewContext;
}

#pragma mark - Saving

- (void)saveContext {
    NSManagedObjectContext *context = self.persistentContainer.viewContext;
    if (![context hasChanges]) {
        return;
    }
    NSError *error = nil;
    if (![context save:&error]) {
        NSLog(@"Unresolved Core Data save error: %@, %@", error, error.userInfo);
    }
}

#pragma mark - Reset

- (void)resetPersistentContainer {
    NSPersistentContainer *container = self.persistentContainer;
    NSPersistentStoreCoordinator *coordinator = container.persistentStoreCoordinator;

    for (NSPersistentStore *store in coordinator.persistentStores) {
        NSURL *storeURL = store.URL;
        NSError *removeError = nil;

        [coordinator removePersistentStore:store error:&removeError];
        if (removeError) {
            NSLog(@"Failed to remove store: %@", removeError);
            continue;
        }

        NSError *fileError = nil;
        [[NSFileManager defaultManager] removeItemAtURL:storeURL error:&fileError];
        if (fileError) {
            NSLog(@"Failed to delete store file: %@", fileError);
        }

        NSError *addError = nil;
        [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                  configuration:nil
                                            URL:storeURL
                                        options:nil
                                          error:&addError];
        if (addError) {
            NSLog(@"Failed to re-add store: %@", addError);
        } else {
            ESLog(@"Persistent store reset successfully.");
        }
    }
}

#pragma mark - CloudKit Sync

- (void)triggerCloudKitSync {
    ESLog(@"Triggering CloudKit sync...");
    [self saveContext];
    NSManagedObjectContext *context = self.viewContext;
    [context performBlock:^{
        [context refreshAllObjects];
        ESLog(@"CloudKit sync refresh completed");
    }];
}

- (void)startObservingCloudKitEvents {
    if (_cloudKitEventObserver) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    _cloudKitEventObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSPersistentCloudKitContainerEventChangedNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *notification) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSPersistentCloudKitContainerEvent *event = notification.userInfo[NSPersistentCloudKitContainerEventUserInfoKey];
        if (event) {
            [strongSelf handleCloudKitEvent:event];
        }
    }];
    ESLog(@"Started observing CloudKit sync events");
}

- (void)stopObservingCloudKitEvents {
    if (_cloudKitEventObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_cloudKitEventObserver];
        _cloudKitEventObserver = nil;
        ESLog(@"Stopped observing CloudKit sync events");
    }
}

- (void)handleCloudKitEvent:(NSPersistentCloudKitContainerEvent *)event {
    NSString *eventType = @"Unknown";
    if (event.type == NSPersistentCloudKitContainerEventTypeSetup) {
        eventType = @"Setup";
    } else if (event.type == NSPersistentCloudKitContainerEventTypeImport) {
        eventType = @"Import";
    } else if (event.type == NSPersistentCloudKitContainerEventTypeExport) {
        eventType = @"Export";
    }
    if (event.error) {
        // CloudKit sync state is shown to the user by the System Pulse CloudKit
        // dots, so we don't also surface sync errors as messages in the System
        // Pulse log. Just log them for diagnosis — the local Core Data store
        // works regardless of whether CloudKit is reachable.
        NSLog(@"CloudKit %@ event error: %@ userInfo=%@", eventType, event.error, event.error.userInfo);
        NSError *underlying = event.error.userInfo[NSUnderlyingErrorKey];
        if (underlying) {
            NSLog(@"CloudKit %@ underlying error: %@ (code %ld, domain %@)",
                  eventType, underlying.localizedDescription,
                  (long)underlying.code, underlying.domain);
        }
        NSNumber *retryAfter = event.error.userInfo[CKErrorRetryAfterKey];
        if (retryAfter != nil) {
            NSLog(@"CloudKit %@ retry after: %@s", eventType, retryAfter);
        }
    } else if (event.succeeded) {
        ESLog(@"CloudKit %@ event succeeded", eventType);
    } else {
        ESLog(@"CloudKit %@ event started", eventType);
    }
}

- (void)dealloc {
    [self stopObservingCloudKitEvents];
}

@end
