//
//  CDMemory.m
//  
//
//  Created by Kolja Wawrowsky on 2/28/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "CDMemory.h"
#import "CDLink.h"
#import "CDLink.h"
#import "CDTag.h"
#import "CDReference.h"
#import "CDMarginalia.h"
#import "CDMemoryRevision.h"

#import "CDVector.h"
#import "CDVector+CoreDataProperties.h"
#import "CDEmbedder.h"
#import "CDEmbedder+CoreDataProperties.h"
#import "CDMemoryLookup.h"
#import "ESSummaryEmbedder.h"

#import "ESCoreDataStack.h"
#import "ESVectorEngine.h"

NSString *const CDMemoryErrorDomain = @"CDMemoryErrorDomain";

@implementation CDMemory

#pragma mark - NSSecureCoding
//
// Archive shape for backup/restore:
//
//   Scalars: uuid, title, body, author, type, summary, locked, private,
//            accessCount, dateCreated, dateModified, dateAccessed
//   Children (cascade-owned, inline): attachments, marginalia, revisions
//   Tags: array of {name, kind} dicts — resolved via CDTag.findByName: on
//         decode. Tags missing on the receiver are skipped (curated layer).
//   Excluded: sourceLinks/targetLinks (encoded at top level as CDLink array),
//             vector (regenerated on save by ESVectorEngine)
//
// Merge policy: last-modified-wins. If an existing CDMemory with the same UUID
// is newer than the incoming record, we keep the existing row unchanged and
// skip decoding children. Otherwise we replace scalars, drop all cascade-owned
// children, and re-attach the decoded set.

+ (BOOL)supportsSecureCoding { return YES; }

// Core Data vends dynamic subclasses of our entity class at runtime (for KVO /
// faulting). Pin the class recorded in the archive to CDMemory so
// NSSecureCoding accepts the encode. CDMemoryRevision declares its own
// override — the unarchiver rejects inherited classForCoder implementations.
- (Class)classForCoder         { return [CDMemory class]; }
- (Class)classForKeyedArchiver { return [CDMemory class]; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid         forKey:@"uuid"];
    [coder encodeObject:self.title        forKey:@"title"];
    [coder encodeObject:self.body         forKey:@"body"];
    [coder encodeObject:self.author       forKey:@"author"];
    [coder encodeObject:self.type         forKey:@"type"];
    [coder encodeObject:self.summary      forKey:@"summary"];
    [coder encodeBool:self.locked         forKey:@"locked"];
    [coder encodeBool:self.private        forKey:@"private"];
    [coder encodeInt64:self.accessCount   forKey:@"accessCount"];
    [coder encodeObject:self.dateCreated  forKey:@"dateCreated"];
    [coder encodeObject:self.dateModified forKey:@"dateModified"];
    [coder encodeObject:self.dateAccessed forKey:@"dateAccessed"];

    // Cascade-owned children — inline.
    [coder encodeObject:self.references.allObjects ?: @[] forKey:@"references"];
    [coder encodeObject:self.marginalia.allObjects   ?: @[] forKey:@"marginalia"];
    [coder encodeObject:self.revisions.allObjects    ?: @[] forKey:@"revisions"];

    // Tags — encoded as {name, kind} dicts since CDTag has no UUID.
    NSMutableArray<NSDictionary *> *tagDicts = [NSMutableArray arrayWithCapacity:self.tags.count];
    for (CDTag *tag in self.tags) {
        if (tag.name.length == 0) continue;
        [tagDicts addObject:@{ @"name": tag.name,
                               @"kind": tag.kind ?: @"thing" }];
    }
    [coder encodeObject:tagDicts forKey:@"tagDicts"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;

    NSUUID *decodedUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"uuid"];
    if (!decodedUUID) {
        NSLog(@"⚠️ [CDMemory Restore] Missing UUID — skipping.");
        return nil;
    }

    // Entity name matches the class name (CDMemory or its sub-entity CDMemoryRevision),
    // so we can use [self class] to pick the right entity when decoding a subclass.
    NSString *entityName = NSStringFromClass([self class]);

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entityName];
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", decodedUUID];
    fetch.fetchLimit = 1;
    fetch.includesSubentities = NO;   // CDMemory/CDMemoryRevision must stay separate
    CDMemory *existing = [[ctx executeFetchRequest:fetch error:nil] firstObject];

    NSDate *incomingModified = [coder decodeObjectOfClass:NSDate.class forKey:@"dateModified"];

    // Last-modified-wins. Keep the existing row if it is newer (or equal in time).
    if (existing && existing.dateModified &&
        (!incomingModified ||
         [existing.dateModified compare:incomingModified] != NSOrderedAscending)) {
        return existing;
    }

    if (existing) {
        // Replace: blow away cascade-owned children before re-attaching decoded
        // ones. The vector is dropped too so the body↔vector relationship can't
        // go stale — ESBackupManager re-enqueues generation after save.
        for (CDReference *a  in [existing.references copy]) [ctx deleteObject:a];
        for (CDMarginalia *m  in [existing.marginalia   copy]) [ctx deleteObject:m];
        for (CDMemoryRevision *r in [existing.revisions copy]) [ctx deleteObject:r];
        // Drop ALL of the existing memory's vectors — this is restore-from-
        // backup, the body is being replaced wholesale; old vectors no longer
        // correspond to any existing content. They get regenerated by
        // ESBackupManager via enqueueVectorForMemory: after save.
        for (CDVector *v in [existing.vectors copy]) [ctx deleteObject:v];
        if (existing.tags.count > 0) {
            [existing removeTags:existing.tags];
        }
        self = existing;
    } else {
        NSEntityDescription *entity = [NSEntityDescription entityForName:entityName
                                                  inManagedObjectContext:ctx];
        self = [super initWithEntity:entity insertIntoManagedObjectContext:ctx];
    }

    if (!self) return nil;

    self.uuid         = decodedUUID;
    self.title        = [coder decodeObjectOfClass:NSString.class forKey:@"title"];
    self.body         = [coder decodeObjectOfClass:NSString.class forKey:@"body"];
    self.author       = [coder decodeObjectOfClass:NSString.class forKey:@"author"];
    self.type         = [coder decodeObjectOfClass:NSString.class forKey:@"type"];
    self.summary      = [coder decodeObjectOfClass:NSString.class forKey:@"summary"];
    self.locked       = [coder decodeBoolForKey:@"locked"];
    self.private      = [coder decodeBoolForKey:@"private"];
    self.accessCount  = [coder decodeInt64ForKey:@"accessCount"];
    self.dateCreated  = [coder decodeObjectOfClass:NSDate.class forKey:@"dateCreated"];
    self.dateModified = incomingModified;
    self.dateAccessed = [coder decodeObjectOfClass:NSDate.class forKey:@"dateAccessed"];

    NSSet<Class> *attachmentClasses = [NSSet setWithObjects:NSArray.class, CDReference.class, nil];
    NSSet<Class> *marginaliaClasses = [NSSet setWithObjects:NSArray.class, CDMarginalia.class, nil];
    NSSet<Class> *revisionClasses   = [NSSet setWithObjects:NSArray.class, CDMemoryRevision.class, nil];

    NSArray<CDReference *> *atts = [coder decodeObjectOfClasses:attachmentClasses forKey:@"references"];
    for (CDReference *a in atts) {
        if ([a isKindOfClass:CDReference.class]) a.memory = self;
    }

    NSArray<CDMarginalia *> *margs = [coder decodeObjectOfClasses:marginaliaClasses forKey:@"marginalia"];
    for (CDMarginalia *m in margs) {
        if ([m isKindOfClass:CDMarginalia.class]) m.memory = self;
    }

    NSArray<CDMemoryRevision *> *revs = [coder decodeObjectOfClasses:revisionClasses forKey:@"revisions"];
    for (CDMemoryRevision *r in revs) {
        if ([r isKindOfClass:CDMemoryRevision.class]) r.memory = self;
    }

    // Tags — connect-or-create. The backup carries {name, kind} per tag, so a
    // tag missing on the receiving side is recreated rather than dropped.
    NSSet<Class> *tagDictClasses = [NSSet setWithObjects:NSArray.class, NSDictionary.class, NSString.class, nil];
    NSArray<NSDictionary *> *tagDicts = [coder decodeObjectOfClasses:tagDictClasses forKey:@"tagDicts"];
    for (NSDictionary *td in tagDicts) {
        if (![td isKindOfClass:NSDictionary.class]) continue;
        NSString *name = td[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
        CDTag *tag = [CDTag findOrCreateByName:name kind:td[@"kind"] context:ctx];
        if (tag) [self addTagsObject:tag];
    }

    return self;
}

#pragma mark - Identity

+ (NSString *)defaultAuthor {
    static NSString *author = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ESDefaultAuthor"];
        author = ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0)
            ? [value copy]
            : @"AI";
    });
    return author;
}

#pragma mark - Factory

+ (CDMemory *)createWithBody:(NSString *)body
                        type:(NSString *)type
                      locked:(BOOL)locked
                     private:(BOOL)isPrivate
                        tags:(NSArray<NSDictionary *> *)tagDicts
                     context:(NSManagedObjectContext *)ctx
                       error:(NSError **)error {

    if (!ctx) {
        if (error) {
            *error = [NSError errorWithDomain:CDMemoryErrorDomain
                                         code:CDMemoryErrorInvalidContext
                                     userInfo:@{NSLocalizedDescriptionKey: @"context must not be nil"}];
        }
        return nil;
    }

    if (!body || ![body isKindOfClass:NSString.class] || body.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:CDMemoryErrorDomain
                                         code:CDMemoryErrorMissingBody
                                     userInfo:@{NSLocalizedDescriptionKey: @"body is required and must be a non-empty string"}];
        }
        return nil;
    }

    CDMemory *memory = [NSEntityDescription insertNewObjectForEntityForName:@"CDMemory"
                                                     inManagedObjectContext:ctx];
    memory.uuid = [NSUUID UUID];
    memory.body = body;
    memory.author = [CDMemory defaultAuthor];
    memory.type = type ?: @"memory";
    memory.locked = locked;
    memory.private = isPrivate;
    memory.dateCreated = [NSDate now];
    memory.dateModified = [NSDate now];
    memory.accessCount = 0;

    [memory extractTitleFromBody];

    // Tags — connect-or-create. A tag the author names is attached; one that
    // doesn't exist yet is created (deliberate authorship, not lexical
    // auto-extraction). kind defaults to "thing" when unspecified.
    if (tagDicts) {
        for (id entry in tagDicts) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *name = ((NSDictionary *)entry)[@"name"];
            if (![name isKindOfClass:NSString.class] || name.length == 0) continue;
            CDTag *tag = [CDTag findOrCreateByName:name kind:((NSDictionary *)entry)[@"kind"] context:ctx];
            if (tag) [memory addTagsObject:tag];
        }
    }

    return memory;
}

#pragma mark - Title Extraction

- (void)extractTitleFromBody {
    if (!self.body || self.body.length == 0) {
        self.title = @"Untitled";
        return;
    }
    NSRange newlineRange = [self.body rangeOfString:@"\n"];
    if (newlineRange.location != NSNotFound) {
        self.title = [self.body substringToIndex:newlineRange.location];
    } else {
        self.title = self.body;
    }
    // Trim whitespace from title
    self.title = [self.title stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.title.length == 0) {
        self.title = @"Untitled";
    }
}

#pragma mark - Access Tracking

- (void)recordAccess {
    self.dateAccessed = [NSDate now];
    self.accessCount += 1; // int64_t scalar — not NSNumber
}

#pragma mark - Semantic Handles

- (NSDictionary *)semanticSummary {
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];
    return @{
        @"title": self.title ?: @"Untitled",
        @"author": self.author ?: [CDMemory defaultAuthor],
        @"type": self.type ?: @"memory",
        @"dateCreated": self.dateCreated ? [df stringFromDate:self.dateCreated] : @"",
        @"accessCount": @(self.accessCount)
    };
}

#pragma mark - Graph Traversal

- (NSArray<CDLink *> *)outgoingLinks {
    return self.sourceLinks.allObjects ?: @[];
}

- (NSArray<CDLink *> *)incomingLinks {
    return self.targetLinks.allObjects ?: @[];
}

- (NSArray<NSDictionary *> *)connectedMemorySummaries {
    NSMutableArray *connections = [NSMutableArray array];

    // Outgoing (this -> target)
    for (CDLink *link in self.sourceLinks) {
        CDMemory *target = (CDMemory *)link.targetMemory;
        if (!target) continue;

        NSMutableDictionary *conn = [NSMutableDictionary dictionary];
        conn[@"direction"] = @"outgoing";
        conn[@"title"] = target.title ?: @"Untitled";
        // First-class CDLink attributes (no JSON parsing needed)
        if (link.linkTitle) conn[@"linkTitle"] = link.linkTitle;
        if (link.linkType) conn[@"type"] = link.linkType;
        if (link.tone) conn[@"tone"] = link.tone;
        if (link.edge) conn[@"edge"] = link.edge;
        [connections addObject:conn];
    }

    // Incoming (source -> this)
    for (CDLink *link in self.targetLinks) {
        CDMemory *source = (CDMemory *)link.sourceMemory;
        if (!source) continue;

        NSMutableDictionary *conn = [NSMutableDictionary dictionary];
        conn[@"direction"] = @"incoming";
        conn[@"title"] = source.title ?: @"Untitled";
        if (link.linkTitle) conn[@"linkTitle"] = link.linkTitle;
        if (link.linkType) conn[@"type"] = link.linkType;
        if (link.tone) conn[@"tone"] = link.tone;
        if (link.edge) conn[@"edge"] = link.edge;
        [connections addObject:conn];
    }

    return connections;
}

#pragma mark - Vector Generation

- (void)generateVector {
    [[ESVectorEngine shared] enqueueVectorForMemory:self];
}

#pragma mark - Vector Selection (multi-embedder)

- (nullable CDVector *)vectorForEmbedderIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    for (CDVector *v in self.vectors) {
        // Prefer the canonical relationship; fall back to the legacy
        // identifier String during the migration window.
        NSString *vid = v.embedder.identifier ?: v.embedderIdentifier;
        if ([vid isEqualToString:identifier]) return v;
    }
    return nil;
}

- (nullable CDVector *)vectorForActiveEmbedder {
    NSString *activeID = [ESVectorEngine summaryEmbedder].identifier;
    if (!activeID) return nil;
    return [self vectorForEmbedderIdentifier:activeID];
}

@end

