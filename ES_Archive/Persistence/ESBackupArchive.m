//
//  ESBackupArchive.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESBackupArchive.h"
#import "CDMemory.h"
#import "CDLink.h"

const int32_t ESBackupArchiveCurrentSchemaVersion = 1;

@implementation ESBackupArchive

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt32:self.schemaVersion    forKey:@"schemaVersion"];
    [coder encodeObject:self.dateCreated     forKey:@"dateCreated"];
    [coder encodeObject:self.appVersion      forKey:@"appVersion"];
    [coder encodeObject:self.memories ?: @[] forKey:@"memories"];
    [coder encodeObject:self.links    ?: @[] forKey:@"links"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (!self) return nil;

    _schemaVersion = [coder decodeInt32ForKey:@"schemaVersion"];
    _dateCreated   = [coder decodeObjectOfClass:NSDate.class   forKey:@"dateCreated"];
    _appVersion    = [coder decodeObjectOfClass:NSString.class forKey:@"appVersion"];

    NSSet<Class> *memoryClasses = [NSSet setWithObjects:NSArray.class, CDMemory.class, nil];
    NSSet<Class> *linkClasses   = [NSSet setWithObjects:NSArray.class, CDLink.class,   nil];

    _memories = [coder decodeObjectOfClasses:memoryClasses forKey:@"memories"] ?: @[];
    _links    = [coder decodeObjectOfClasses:linkClasses   forKey:@"links"]    ?: @[];

    return self;
}

@end
