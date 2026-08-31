//
//  CDLink.m
//  
//
//  Created by Kolja Wawrowsky on 2/28/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "CDLink.h"
#import "CDMemory.h"
#import "ESCoreDataStack.h"

@implementation CDLink

#pragma mark - NSSecureCoding
//
// Two-pass pattern (mirrors AI_Server/CDLink.m): encode sourceMemory/targetMemory
// as UUIDs, and resolve them by UUID-lookup against the viewContext during decode.
// This is the "entities first, links second" phase of the backup/restore workflow
// — callers must unarchive all CDMemory objects before unarchiving CDLinks.
//
// Links are treated as immutable: on UUID collision we return the existing link
// unchanged (no dateModified on CDLink to compare).
//
// Orphan handling: a link whose source or target is still missing after the
// memory phase is logged and dropped by ESBackupManager. Inside initWithCoder:
// we just assign whatever we can find — the manager does the orphan sweep.

+ (BOOL)supportsSecureCoding { return YES; }

// Pin the archived class against Core Data's dynamic runtime subclasses.
- (Class)classForCoder         { return [CDLink class]; }
- (Class)classForKeyedArchiver { return [CDLink class]; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid        forKey:@"uuid"];
    [coder encodeObject:self.dateCreated forKey:@"dateCreated"];
    [coder encodeObject:self.linkTitle   forKey:@"linkTitle"];
    [coder encodeObject:self.linkType    forKey:@"linkType"];
    [coder encodeObject:self.edge        forKey:@"edge"];
    [coder encodeObject:self.tone        forKey:@"tone"];

    // Relationships as UUIDs.
    [coder encodeObject:self.sourceMemory.uuid forKey:@"sourceUUID"];
    [coder encodeObject:self.targetMemory.uuid forKey:@"targetUUID"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;

    NSUUID *decodedUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"uuid"];
    if (!decodedUUID) {
        NSLog(@"⚠️ [CDLink Restore] Missing UUID — skipping.");
        return nil;
    }

    NSFetchRequest *fetch = [CDLink fetchRequest];
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", decodedUUID];
    fetch.fetchLimit = 1;
    CDLink *existing = [[ctx executeFetchRequest:fetch error:nil] firstObject];

    if (existing) {
        // Link already present — treat as immutable and keep the existing row.
        return existing;
    }

    NSEntityDescription *entity = [NSEntityDescription entityForName:@"CDLink"
                                              inManagedObjectContext:ctx];
    self = [super initWithEntity:entity insertIntoManagedObjectContext:ctx];

    if (self) {
        self.uuid        = decodedUUID;
        self.dateCreated = [coder decodeObjectOfClass:NSDate.class   forKey:@"dateCreated"];
        self.linkTitle   = [coder decodeObjectOfClass:NSString.class forKey:@"linkTitle"];
        self.linkType    = [coder decodeObjectOfClass:NSString.class forKey:@"linkType"];
        self.edge        = [coder decodeObjectOfClass:NSString.class forKey:@"edge"];
        self.tone        = [coder decodeObjectOfClass:NSString.class forKey:@"tone"];

        NSUUID *srcUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"sourceUUID"];
        NSUUID *tgtUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"targetUUID"];

        if (srcUUID) self.sourceMemory = [CDLink _findMemoryWithUUID:srcUUID inContext:ctx];
        if (tgtUUID) self.targetMemory = [CDLink _findMemoryWithUUID:tgtUUID inContext:ctx];

        if (!self.sourceMemory || !self.targetMemory) {
            NSLog(@"⚠️ [CDLink Restore] Orphan link %@ (src=%@ tgt=%@) — will be swept by ESBackupManager",
                  self.uuid, srcUUID, tgtUUID);
        }
    }
    return self;
}

+ (nullable CDMemory *)_findMemoryWithUUID:(NSUUID *)uuid
                                 inContext:(NSManagedObjectContext *)ctx {
    NSFetchRequest *fetch = [CDMemory fetchRequest];
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", uuid];
    fetch.fetchLimit = 1;
    fetch.includesSubentities = NO;         // exclude CDMemoryRevision
    fetch.returnsObjectsAsFaults = YES;     // keep memory footprint low
    return [[ctx executeFetchRequest:fetch error:nil] firstObject];
}

@end
