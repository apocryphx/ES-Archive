//
//  ESVectorCacheEntry.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESVectorCacheEntry.h"

@implementation ESVectorCacheEntry

- (instancetype)initWithVectorData:(NSData *)vectorData
                       accessCount:(NSUInteger)accessCount
              lastAccessedTimestamp:(NSTimeInterval)lastAccessedTimestamp
                 creationTimestamp:(NSTimeInterval)creationTimestamp {
    self = [super init];
    if (self) {
        _vectorData = vectorData;
        _accessCount = accessCount;
        _lastAccessedTimestamp = lastAccessedTimestamp;
        _creationTimestamp = creationTimestamp;
    }
    return self;
}

@end
