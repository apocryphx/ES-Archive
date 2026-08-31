//
//  ESBackupManager.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESBackupManager.h"
#import "ESBackupArchive.h"
#import "ESCoreDataStack.h"
#import "ESLog.h"

#import "CDMemory.h"
#import "CDLink.h"
#import "CDVector.h"
#import "ESVectorEngine.h"

NSString *const ESBackupManagerErrorDomain = @"ESBackupManagerErrorDomain";

@implementation ESBackupRestoreSummary
@end

@implementation ESBackupManager

#pragma mark - Backup

+ (BOOL)writeBackupToURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) *error = [self errorWithCode:ESBackupManagerErrorInvalidURL
                                        message:@"Destination URL was nil."];
        return NO;
    }

    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;

    // Sandbox: if the URL came from NSSavePanel, the file-coordination grant
    // travels with the URL; otherwise begin/end access around the write.
    BOOL usingScope = [url startAccessingSecurityScopedResource];

    __block NSError *fetchErr = nil;
    __block NSArray<CDMemory *> *memories = @[];
    __block NSArray<CDLink   *> *links    = @[];

    [ctx performBlockAndWait:^{
        NSFetchRequest *memFetch = [CDMemory fetchRequest];
        memFetch.includesSubentities = NO;   // CDMemoryRevision rides inside its parent
        NSArray *mems = [ctx executeFetchRequest:memFetch error:&fetchErr];
        if (!fetchErr) memories = mems;

        if (!fetchErr) {
            NSFetchRequest *linkFetch = [CDLink fetchRequest];
            NSArray *lks = [ctx executeFetchRequest:linkFetch error:&fetchErr];
            if (!fetchErr) links = lks;
        }
    }];

    if (fetchErr) {
        if (usingScope) [url stopAccessingSecurityScopedResource];
        if (error) *error = fetchErr;
        return NO;
    }

    ESBackupArchive *archive = [ESBackupArchive new];
    archive.schemaVersion = ESBackupArchiveCurrentSchemaVersion;
    archive.dateCreated   = [NSDate date];
    archive.appVersion    = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    archive.memories      = memories;
    archive.links         = links;

    NSError *encodeErr = nil;
    NSData *data = nil;
    @try {
        data = [NSKeyedArchiver archivedDataWithRootObject:archive
                                     requiringSecureCoding:YES
                                                     error:&encodeErr];
    } @catch (NSException *ex) {
        NSLog(@"💥 [ESBackupManager] Encode exception: %@ — %@\nuserInfo: %@",
              ex.name, ex.reason, ex.userInfo);
        if (!encodeErr) {
            encodeErr = [NSError errorWithDomain:ESBackupManagerErrorDomain
                                            code:ESBackupManagerErrorArchiveWriteFailed
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Encoder raised %@: %@", ex.name, ex.reason ?: @"(no reason)"]
            }];
        }
    }
    if (!data) {
        NSLog(@"💥 [ESBackupManager] Encode failed: %@\nuserInfo: %@",
              encodeErr.localizedDescription, encodeErr.userInfo);
        if (usingScope) [url stopAccessingSecurityScopedResource];
        if (error) *error = encodeErr ?: [self errorWithCode:ESBackupManagerErrorArchiveWriteFailed
                                                     message:@"NSKeyedArchiver returned no data."];
        return NO;
    }

    NSError *writeErr = nil;
    BOOL wrote = [data writeToURL:url
                          options:NSDataWritingAtomic
                            error:&writeErr];
    if (usingScope) [url stopAccessingSecurityScopedResource];

    if (!wrote) {
        if (error) *error = writeErr ?: [self errorWithCode:ESBackupManagerErrorArchiveWriteFailed
                                                    message:@"Failed to write backup file."];
        return NO;
    }
    return YES;
}

#pragma mark - Restore

+ (nullable ESBackupRestoreSummary *)restoreBackupFromURL:(NSURL *)url
                                                    error:(NSError **)error {
    if (!url) {
        if (error) *error = [self errorWithCode:ESBackupManagerErrorInvalidURL
                                        message:@"Source URL was nil."];
        return nil;
    }

    BOOL usingScope = [url startAccessingSecurityScopedResource];

    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readErr];
    if (!data) {
        if (usingScope) [url stopAccessingSecurityScopedResource];
        if (error) *error = readErr ?: [self errorWithCode:ESBackupManagerErrorFileAccessDenied
                                                   message:@"Could not read backup file."];
        return nil;
    }

    // Snapshot current store shape so we can diff after decode. Decoding runs
    // synchronously on the main queue — the CD* initWithCoder: implementations
    // upsert directly into ESCoreDataStack.shared.viewContext.
    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;
    __block NSSet<NSUUID *> *memoryUUIDsBefore = [NSSet set];
    __block NSSet<NSUUID *> *linkUUIDsBefore   = [NSSet set];

    [ctx performBlockAndWait:^{
        memoryUUIDsBefore = [self _uuidSetForEntity:@"CDMemory" includesSubentities:NO inContext:ctx];
        linkUUIDsBefore   = [self _uuidSetForEntity:@"CDLink"   includesSubentities:NO inContext:ctx];
    }];

    NSError *decodeErr = nil;
    ESBackupArchive *archive = nil;
    @try {
        archive = [NSKeyedUnarchiver unarchivedObjectOfClass:ESBackupArchive.class
                                                    fromData:data
                                                       error:&decodeErr];
    } @catch (NSException *ex) {
        NSLog(@"💥 [ESBackupManager] Decode exception: %@ — %@\nuserInfo: %@",
              ex.name, ex.reason, ex.userInfo);
        if (!decodeErr) {
            decodeErr = [NSError errorWithDomain:ESBackupManagerErrorDomain
                                            code:ESBackupManagerErrorArchiveReadFailed
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Unarchiver raised %@: %@", ex.name, ex.reason ?: @"(no reason)"]
            }];
        }
    }
    if (usingScope) [url stopAccessingSecurityScopedResource];

    if (!archive) {
        NSLog(@"💥 [ESBackupManager] Decode failed: %@\nuserInfo: %@\nfile: %@ (%lu bytes)",
              decodeErr.localizedDescription, decodeErr.userInfo,
              url.lastPathComponent, (unsigned long)data.length);
        if (error) *error = decodeErr ?: [self errorWithCode:ESBackupManagerErrorArchiveReadFailed
                                                     message:@"Backup file is corrupt or not an ES Archive archive."];
        [ctx rollback];
        return nil;
    }

    if (archive.schemaVersion > ESBackupArchiveCurrentSchemaVersion) {
        if (error) *error = [self errorWithCode:ESBackupManagerErrorUnsupportedSchema
                                        message:[NSString stringWithFormat:
                                                 @"Backup was created by a newer version (schema v%d). This build understands up to v%d.",
                                                 archive.schemaVersion, ESBackupArchiveCurrentSchemaVersion]];
        [ctx rollback];
        return nil;
    }

    // Orphan sweep: any CDLink whose source or target is still nil after the
    // memory phase means the referenced memory is in neither the archive nor
    // the pre-existing store. Drop it.
    __block NSUInteger orphanDropped = 0;
    [ctx performBlockAndWait:^{
        for (CDLink *link in archive.links) {
            if (!link.sourceMemory || !link.targetMemory) {
                [ctx deleteObject:link];
                orphanDropped++;
            }
        }
    }];

    // Save. A failure here leaves Core Data dirty — roll back so the store
    // matches what the user saw before the restore attempt.
    __block NSError *saveErr = nil;
    [ctx performBlockAndWait:^{
        if (ctx.hasChanges) {
            if (![ctx save:&saveErr]) {
                [ctx rollback];
            }
        }
    }];

    if (saveErr) {
        if (error) *error = [NSError errorWithDomain:ESBackupManagerErrorDomain
                                                code:ESBackupManagerErrorContextSaveFailed
                                            userInfo:@{
            NSLocalizedDescriptionKey: @"Failed to save restored memories to the store.",
            NSUnderlyingErrorKey: saveErr
        }];
        return nil;
    }

    // Regenerate vectors for memories without one. New inserts have no vector
    // at all; replaced memories had their stale vector deleted in the "replace"
    // branch of CDMemory initWithCoder:. Kept-existing memories retain their
    // vector and are skipped by the nil check.
    __block NSUInteger enqueued = 0;
    [ctx performBlockAndWait:^{
        for (CDMemory *m in archive.memories) {
            if (m.managedObjectContext == nil) continue;
            // Enqueue regeneration if no vector exists for the active embedder.
            // Vectors from other embedders (multi-device sync state) are
            // preserved but don't substitute for an active-embedder vector.
            if ([m vectorForActiveEmbedder] == nil) {
                [[ESVectorEngine shared] enqueueVectorForMemory:m];
                enqueued++;
            }
        }
    }];
    ESLog(@"🔁 [ESBackupManager] Enqueued %lu memories for vector regeneration",
          (unsigned long)enqueued);

    ESBackupRestoreSummary *summary = [ESBackupRestoreSummary new];

    NSUInteger incomingMemCount  = archive.memories.count;
    NSUInteger incomingLinkCount = archive.links.count;

    // A memory counts as "restored" when its UUID did not exist before OR when
    // decode replaced the existing row (which we observe as dateModified moving
    // forward — but simpler here: new-UUIDs vs. overlap-and-newer). To avoid a
    // second pass, approximate: memories whose UUIDs weren't in `before` are new;
    // the rest are "replaced or kept". We refine by comparing dateModified sets.
    __block NSUInteger newMemories    = 0;
    __block NSUInteger replacedOrKept = 0;
    [ctx performBlockAndWait:^{
        for (CDMemory *m in archive.memories) {
            if ([memoryUUIDsBefore containsObject:m.uuid]) {
                replacedOrKept++;
            } else {
                newMemories++;
            }
        }
    }];
    summary.memoriesRestored = newMemories + replacedOrKept; // bulk count surfaced to user
    summary.memoriesSkipped  = 0;                            // refined below if needed

    __block NSUInteger newLinks  = 0;
    __block NSUInteger keptLinks = 0;
    [ctx performBlockAndWait:^{
        for (CDLink *l in archive.links) {
            if (l.managedObjectContext == nil) continue; // deleted by orphan sweep
            if ([linkUUIDsBefore containsObject:l.uuid]) {
                keptLinks++;
            } else {
                newLinks++;
            }
        }
    }];
    summary.linksRestored     = newLinks;
    summary.linksSkipped      = keptLinks;
    summary.linksOrphanDropped = orphanDropped;

    ESLog(@"✅ [ESBackupManager] Restored from %@: memories=%lu (new=%lu overlap=%lu) links=%lu (new=%lu kept=%lu orphan=%lu) total in archive: memories=%lu links=%lu",
          url.lastPathComponent,
          (unsigned long)summary.memoriesRestored,
          (unsigned long)newMemories,
          (unsigned long)replacedOrKept,
          (unsigned long)(summary.linksRestored + summary.linksSkipped),
          (unsigned long)summary.linksRestored,
          (unsigned long)summary.linksSkipped,
          (unsigned long)summary.linksOrphanDropped,
          (unsigned long)incomingMemCount,
          (unsigned long)incomingLinkCount);

    return summary;
}

#pragma mark - Helpers

+ (NSSet<NSUUID *> *)_uuidSetForEntity:(NSString *)entityName
                   includesSubentities:(BOOL)includesSub
                             inContext:(NSManagedObjectContext *)ctx {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entityName];
    fetch.includesSubentities = includesSub;
    fetch.resultType = NSDictionaryResultType;
    fetch.propertiesToFetch = @[@"uuid"];

    NSArray *rows = [ctx executeFetchRequest:fetch error:nil] ?: @[];
    NSMutableSet<NSUUID *> *set = [NSMutableSet setWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        NSUUID *u = row[@"uuid"];
        if ([u isKindOfClass:NSUUID.class]) [set addObject:u];
    }
    return set;
}

+ (NSError *)errorWithCode:(ESBackupManagerErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:ESBackupManagerErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

@end
