//
//  CDMemoryRevision.m
//  
//
//  Created by Kolja Wawrowsky on 2/28/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "CDMemoryRevision.h"

@implementation CDMemoryRevision

#pragma mark - NSSecureCoding

// Apple's rule: any subclass that overrides initWithCoder: must also override
// +supportsSecureCoding. Inherited YES isn't enough for the archiver's checks.
+ (BOOL)supportsSecureCoding { return YES; }

// Must be declared on THIS class (not inherited) — NSKeyedUnarchiver rejects
// the decoded object with "classForCoder is inherited from a superclass" if
// the override only lives on CDMemory.
- (Class)classForCoder         { return [CDMemoryRevision class]; }
- (Class)classForKeyedArchiver { return [CDMemoryRevision class]; }
//
// CDMemoryRevision is a Core Data sub-entity of CDMemory, so it inherits every
// attribute plus adds `reason`. Super handles the common fields (and picks the
// right entity via [self class] when inserting). We only need to carry `reason`.

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeObject:self.reason forKey:@"reason"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        self.reason = [coder decodeObjectOfClass:NSString.class forKey:@"reason"];
    }
    return self;
}

@end
