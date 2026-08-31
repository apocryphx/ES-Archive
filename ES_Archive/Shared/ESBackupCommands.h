//
//  ESBackupCommands.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The Back Up… and Restore… commands, shared by both apps.
///
/// Each app used to carry its own copy — -[AppDelegate backUpDatabase:] and
/// -[ESStdioAppDelegate backUp:] were identical apart from the selector name —
/// and both already wrote through the shared ESBackupManager, so only the panel
/// and alert presentation was duplicated. The app delegates keep their own
/// selectors as thin forwarders, since the menus and status items target those.
@interface ESBackupCommands : NSObject

/// Save panel → ESBackupManager, then a completion or failure alert.
+ (void)presentBackupPanel;

/// Confirmation → open panel → ESBackupManager, then a summary or failure alert.
+ (void)presentRestorePanel;

#pragma mark - Sample memories

/// Whether this build carries the bundled sample archive. NO means the resource
/// is missing, and the Connect window hides its section rather than offering a
/// button that cannot work.
+ (BOOL)hasSampleArchive;

/// Merge the bundled sample archive into the user's own, so a fresh install has
/// something to search, link and look at in the Archive Scope. Confirmation
/// first, then the same ESBackupManager restore path as +presentRestorePanel —
/// the archive IS a backup, made with the backup command.
///
/// Returns YES only when memories were actually added — NO if the user
/// cancelled, the resource is missing, or the restore failed. The caller uses
/// that to decide what to show next; this class does the data work and reports.
+ (BOOL)presentSampleMemoriesInstall;

@end

NS_ASSUME_NONNULL_END
