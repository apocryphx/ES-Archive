//
//  ESBackupManager.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Orchestrates backup (fetch → ESBackupArchive → NSKeyedArchiver → .essheep)
//  and restore (NSKeyedUnarchiver → ESBackupArchive → Core Data save), including
//  the post-restore orphan-link sweep. All Core Data access runs on the main
//  queue (viewContext). IBActions on AppDelegate already run on main, so no
//  cross-thread dispatch is required here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSString *const ESBackupManagerErrorDomain;

typedef NS_ENUM(NSInteger, ESBackupManagerErrorCode) {
    ESBackupManagerErrorInvalidURL           = 4000,
    ESBackupManagerErrorArchiveWriteFailed   = 4001,
    ESBackupManagerErrorArchiveReadFailed    = 4002,
    ESBackupManagerErrorUnsupportedSchema    = 4003,
    ESBackupManagerErrorContextSaveFailed    = 4004,
    ESBackupManagerErrorFileAccessDenied     = 4005,
};

/// Summary of a restore operation — counts reported in the completion alert.
@interface ESBackupRestoreSummary : NSObject
@property (nonatomic, assign) NSUInteger memoriesRestored;   // replaced or newly inserted
@property (nonatomic, assign) NSUInteger memoriesSkipped;    // kept existing (existing newer than archive)
@property (nonatomic, assign) NSUInteger linksRestored;      // newly inserted
@property (nonatomic, assign) NSUInteger linksSkipped;       // already present
@property (nonatomic, assign) NSUInteger linksOrphanDropped; // source or target missing after memory phase
@end

@interface ESBackupManager : NSObject

/// Write a snapshot of the entire memory graph (excluding vectors) to `url`.
/// The URL must be security-scoped or otherwise accessible — callers using
/// NSSavePanel pass its resulting URL directly (sandbox grants file access via
/// the panel).
+ (BOOL)writeBackupToURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;

/// Restore a `.essheep` archive into the current viewContext, applying the
/// last-modified-wins merge policy in CDMemory's initWithCoder:. Returns a
/// per-run summary that the caller can surface in an NSAlert.
+ (nullable ESBackupRestoreSummary *)restoreBackupFromURL:(NSURL *)url
                                                    error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
