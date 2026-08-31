//
//  CDMarginalia.m
//  
//
//  Created by Kolja Wawrowsky on 3/4/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "CDMarginalia.h"
#import "ESCoreDataStack.h"

@implementation CDMarginalia

#pragma mark - NSSecureCoding
//
// Marginal note: plain scalar encode. Inverse `memory` relationship is set by
// the parent CDMemory during its own decode. Upsert by UUID.

+ (BOOL)supportsSecureCoding { return YES; }

// Pin the archived class against Core Data's dynamic runtime subclasses.
- (Class)classForCoder         { return [CDMarginalia class]; }
- (Class)classForKeyedArchiver { return [CDMarginalia class]; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid        forKey:@"uuid"];
    [coder encodeObject:self.body        forKey:@"body"];
    [coder encodeObject:self.author      forKey:@"author"];
    [coder encodeObject:self.dateCreated forKey:@"dateCreated"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSManagedObjectContext *ctx = ESCoreDataStack.shared.viewContext;
    NSUUID *decodedUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"uuid"];
    if (!decodedUUID) {
        NSLog(@"⚠️ [CDMarginalia Restore] Missing UUID — skipping.");
        return nil;
    }

    NSFetchRequest *fetch = [CDMarginalia fetchRequest];
    fetch.predicate = [NSPredicate predicateWithFormat:@"uuid == %@", decodedUUID];
    fetch.fetchLimit = 1;
    CDMarginalia *existing = [[ctx executeFetchRequest:fetch error:nil] firstObject];

    if (existing) {
        self = existing;
    } else {
        NSEntityDescription *entity = [NSEntityDescription entityForName:@"CDMarginalia"
                                                  inManagedObjectContext:ctx];
        self = [super initWithEntity:entity insertIntoManagedObjectContext:ctx];
    }

    if (self) {
        self.uuid        = decodedUUID;
        self.body        = [coder decodeObjectOfClass:NSString.class forKey:@"body"];
        self.author      = [coder decodeObjectOfClass:NSString.class forKey:@"author"];
        self.dateCreated = [coder decodeObjectOfClass:NSDate.class   forKey:@"dateCreated"];
    }
    return self;
}

#pragma mark - Factory

+ (instancetype)createOnMemory:(CDMemory *)memory
                          body:(NSString *)body
                        author:(NSString *)author
                       context:(NSManagedObjectContext *)context {

    CDMarginalia *note = [NSEntityDescription insertNewObjectForEntityForName:@"CDMarginalia"
                                                      inManagedObjectContext:context];
    note.uuid = [NSUUID UUID];
    note.body = body;
    note.author = author;
    note.dateCreated = [NSDate dateWithTimeIntervalSince1970:floor([NSDate now].timeIntervalSince1970)];
    note.memory = memory;
    return note;
}

@end
