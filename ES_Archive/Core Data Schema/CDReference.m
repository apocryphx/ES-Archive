//
//  CDReference+CoreDataClass.m
//  ES Archive
//
//  Created by Kolja Wawrowsky on 6/27/26.
//

#import "CDReference.h"
#import "CDMemory.h"
#import "ESCoreDataStack.h"

@implementation CDReference

#pragma mark - NSSecureCoding
//
// Encodes scalar fields only. The inverse `memory` relationship is set by the
// parent CDMemory during its own decode. Upsert-by-UUID: a reference with the
// same UUID is reused; otherwise a fresh row is inserted into the viewContext.
// No payload is encoded — a reference points, it does not contain.

+ (BOOL)supportsSecureCoding { return YES; }

// Pin the archived class against Core Data's dynamic runtime subclasses.
- (Class)classForCoder         { return [CDReference class]; }
- (Class)classForKeyedArchiver { return [CDReference class]; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid             forKey:@"uuid"];
    [coder encodeObject:self.type             forKey:@"type"];
    [coder encodeObject:self.handle           forKey:@"handle"];
    [coder encodeObject:self.title            forKey:@"title"];
    [coder encodeObject:self.url              forKey:@"url"];
    [coder encodeObject:self.contentType      forKey:@"contentType"];
    [coder encodeObject:self.bookmark         forKey:@"bookmark"];
    [coder encodeObject:self.note             forKey:@"note"];
    [coder encodeObject:self.author           forKey:@"author"];
    [coder encodeObject:self.dateCreated      forKey:@"dateCreated"];
    [coder encodeObject:self.dateLastResolved forKey:@"dateLastResolved"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;
    NSUUID *decodedUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"uuid"];
    if (!decodedUUID) {
        NSLog(@"⚠️ [CDReference Restore] Missing UUID — skipping.");
        return nil;
    }

    NSFetchRequest *fetch = [CDReference fetchRequest];
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", decodedUUID];
    fetch.fetchLimit = 1;
    CDReference *existing = [[ctx executeFetchRequest:fetch error:nil] firstObject];

    if (existing) {
        self = existing;
    } else {
        NSEntityDescription *entity = [NSEntityDescription entityForName:@"CDReference"
                                                  inManagedObjectContext:ctx];
        self = [super initWithEntity:entity insertIntoManagedObjectContext:ctx];
    }

    if (self) {
        self.uuid             = decodedUUID;
        self.type             = [coder decodeObjectOfClass:NSString.class forKey:@"type"];
        self.handle           = [coder decodeObjectOfClass:NSString.class forKey:@"handle"];
        self.title            = [coder decodeObjectOfClass:NSString.class forKey:@"title"];
        self.url              = [coder decodeObjectOfClass:NSString.class forKey:@"url"];
        self.contentType      = [coder decodeObjectOfClass:NSString.class forKey:@"contentType"];
        self.bookmark         = [coder decodeObjectOfClass:NSData.class   forKey:@"bookmark"];
        self.note             = [coder decodeObjectOfClass:NSString.class forKey:@"note"];
        self.author           = [coder decodeObjectOfClass:NSString.class forKey:@"author"];
        self.dateCreated      = [coder decodeObjectOfClass:NSDate.class   forKey:@"dateCreated"];
        self.dateLastResolved = [coder decodeObjectOfClass:NSDate.class   forKey:@"dateLastResolved"];
    }
    return self;
}

#pragma mark - Factory

+ (instancetype)createOnMemory:(CDMemory *)memory
                          type:(NSString *)type
                        handle:(nullable NSString *)handle
                         title:(nullable NSString *)title
                           url:(nullable NSString *)url
                   contentType:(nullable NSString *)contentType
                          note:(nullable NSString *)note
                        author:(nullable NSString *)author
                       context:(NSManagedObjectContext *)context {

    CDReference *ref = [NSEntityDescription insertNewObjectForEntityForName:@"CDReference"
                                                    inManagedObjectContext:context];
    ref.uuid = [NSUUID UUID];
    ref.type = type;
    ref.handle = handle;
    ref.title = title;
    ref.url = url;
    ref.contentType = contentType;
    ref.note = note;
    ref.author = author;
    // Truncate to whole seconds so the dateCreated round-trips exactly through
    // ISO8601 (the remove/lookup path matches by timestamp).
    ref.dateCreated = [NSDate dateWithTimeIntervalSince1970:floor([NSDate now].timeIntervalSince1970)];
    ref.memory = memory;
    return ref;
}

@end
