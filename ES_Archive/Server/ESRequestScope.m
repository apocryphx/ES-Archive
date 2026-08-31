//
//  ESRequestScope.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESRequestScope.h"
#import "CDMemory.h"

@implementation ESRequestScope

+ (instancetype)scopeWithAuthor:(NSString *)author {
    return [[self alloc] initWithAuthor:author];
}

- (instancetype)initWithAuthor:(NSString *)author {
    self = [super init];
    if (self) {
        // Resolve once, here, so downstream never re-runs the chain.
        // +[CDMemory defaultAuthor] already terminates in @"AI".
        NSString *resolved = ([author isKindOfClass:NSString.class] && author.length > 0)
            ? author
            : [CDMemory defaultAuthor];
        _author = [resolved copy];
    }
    return self;
}

@end
