//
//  ESBackupCommands.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESBackupCommands.h"
#import "ESBackupManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// The bundled sample archive — an ordinary .esarchive backup, produced with the
/// backup command and shipped as a resource.
static NSString * const kSampleArchiveName      = @"Demo-Data";
static NSString * const kSampleArchiveExtension = @"esarchive";

@implementation ESBackupCommands

/// Matches UTExportedTypeDeclarations in ES-Memory-Info.plist.
+ (nullable UTType *)archiveType {
    return [UTType typeWithIdentifier:@"com.elarity.es-memory.backup"]
        ?: [UTType typeWithFilenameExtension:@"esarchive" conformingToType:UTTypeData];
}

+ (void)presentBackupPanel {
    // Both apps can be running as an Accessory (menu-bar only), where panels
    // open behind the frontmost app unless we activate first.
    [NSApp activateIgnoringOtherApps:YES];

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Back Up Memory Archive";
    panel.message = @"Save a snapshot of every memory, tag, and link. "
                    @"Vectors are excluded and regenerate after restore.";
    panel.prompt = @"Back Up";
    panel.canCreateDirectories = YES;

    UTType *esarchiveType = [self archiveType];
    if (esarchiveType) {
        panel.allowedContentTypes = @[ esarchiveType ];
    }

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"ES_Backup-%@.esarchive",
                                  [df stringFromDate:[NSDate date]]];

    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSError *err = nil;
    if (![ESBackupManager writeBackupToURL:panel.URL error:&err]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Backup failed";
        alert.informativeText = err.localizedDescription ?: @"Unknown error.";
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return;
    }

    NSAlert *done = [NSAlert new];
    done.messageText = @"Backup complete";
    done.informativeText = [NSString stringWithFormat:@"Archive written to:\n%@",
                            panel.URL.path];
    [done runModal];
}

+ (void)presentRestorePanel {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *confirm = [NSAlert new];
    confirm.messageText = @"Restore from backup?";
    confirm.informativeText = @"The selected archive will be merged into the current memory store. "
                              @"On UUID conflicts, the record with the newer last-modified date wins. "
                              @"Vectors will be regenerated in the background.";
    [confirm addButtonWithTitle:@"Choose Backup…"];
    [confirm addButtonWithTitle:@"Cancel"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Restore Memory Archive";
    panel.prompt = @"Restore";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;

    UTType *esarchiveType = [self archiveType];
    if (esarchiveType) {
        panel.allowedContentTypes = @[ esarchiveType ];
    }

    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;

    NSError *err = nil;
    ESBackupRestoreSummary *summary = [ESBackupManager restoreBackupFromURL:panel.URL
                                                                      error:&err];
    if (!summary) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Restore failed";
        alert.informativeText = err.localizedDescription ?: @"Unknown error.";
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return;
    }

    NSAlert *done = [NSAlert new];
    done.messageText = @"Restore complete";
    done.informativeText = [NSString stringWithFormat:
                            @"Memories processed: %lu\n"
                            @"Links inserted: %lu  (already present: %lu)\n"
                            @"Orphan links dropped: %lu",
                            (unsigned long)summary.memoriesRestored,
                            (unsigned long)summary.linksRestored,
                            (unsigned long)summary.linksSkipped,
                            (unsigned long)summary.linksOrphanDropped];
    [done runModal];
}

#pragma mark - Sample memories

+ (nullable NSURL *)sampleArchiveURL {
    return [NSBundle.mainBundle URLForResource:kSampleArchiveName
                                 withExtension:kSampleArchiveExtension];
}

+ (BOOL)hasSampleArchive {
    return [self sampleArchiveURL] != nil;
}

+ (BOOL)presentSampleMemoriesInstall {
    [NSApp activateIgnoringOtherApps:YES];

    NSURL *archive = [self sampleArchiveURL];
    if (!archive) return NO;   // the section is hidden in this case; belt and braces

    NSAlert *confirm = [NSAlert new];
    confirm.messageText = @"Add sample memories?";
    // Say plainly that this is a merge into the real archive and that it is not
    // a mode the user can switch back off — the memories are ordinary ones
    // afterwards, carrying no marker that would let the app find them again.
    confirm.informativeText =
        @"A set of example memories, tags and links will be added to your archive so there is "
        @"something to search, connect and explore straight away.\n\n"
        @"They become ordinary memories: nothing marks them as samples, so removing them later "
        @"means deleting them individually. Adding them twice is harmless — matching records "
        @"are recognised rather than duplicated.";
    [confirm addButtonWithTitle:@"Add Sample Memories"];
    [confirm addButtonWithTitle:@"Cancel"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return NO;

    NSError *err = nil;
    ESBackupRestoreSummary *summary = [ESBackupManager restoreBackupFromURL:archive error:&err];
    if (!summary) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn’t add the sample memories";
        alert.informativeText = err.localizedDescription ?: @"Unknown error.";
        alert.alertStyle = NSAlertStyleCritical;
        [alert runModal];
        return NO;
    }

    NSAlert *done = [NSAlert new];
    done.messageText = @"Sample memories added";
    done.informativeText = [NSString stringWithFormat:
                            @"%lu memories and %lu links are now in your archive. "
                            @"Vectors regenerate in the background, so search results improve "
                            @"over the next few moments.",
                            (unsigned long)summary.memoriesRestored,
                            (unsigned long)summary.linksRestored];
    [done runModal];
    return YES;
}

@end
