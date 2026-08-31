//
//  TopKScores.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTopKScores.h"

@implementation ESTopKScores {
    NSMutableArray *_entries;
    NSUInteger _maxCount;
}

- (instancetype)initWithCapacity:(NSUInteger)k {
    if (self = [super init]) {
        _entries = [NSMutableArray arrayWithCapacity:k];
        _maxCount = k;
    }
    return self;
}

- (void)addScore:(float)score forObjectID:(NSManagedObjectID *)objectID {
    [self addScore:score cosine:score forObjectID:objectID];
}

- (void)addScore:(float)score
          cosine:(float)cosine
     forObjectID:(NSManagedObjectID *)objectID {
    if (_entries.count == _maxCount) {
        float worstScore = [_entries.lastObject[@"score"] floatValue];
        if (score <= worstScore) {
            return;
        }
    }

    NSDictionary *entry = @{@"score": @(score), @"cosine": @(cosine), @"objectID": objectID};

    NSUInteger index = [_entries indexOfObject:entry
                                 inSortedRange:NSMakeRange(0, _entries.count)
                                       options:NSBinarySearchingInsertionIndex | NSBinarySearchingFirstEqual
                               usingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        float s1 = [obj1[@"score"] floatValue];
        float s2 = [obj2[@"score"] floatValue];
        if (s1 > s2) return NSOrderedAscending;
        if (s1 < s2) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (index < _maxCount) {
        [_entries insertObject:entry atIndex:index];
        if (_entries.count > _maxCount) {
            [_entries removeLastObject];
        }
    }
}

- (NSArray<NSManagedObjectID *> *)topObjectIDs {
    return [_entries valueForKey:@"objectID"];
}

- (NSArray<NSDictionary *> *)topEntries {
    return [_entries copy];
}

@end
