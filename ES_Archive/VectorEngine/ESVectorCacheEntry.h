//
//  ESVectorCacheEntry.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Cache entry holding vector data plus metadata for decay scoring.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESVectorCacheEntry : NSObject

@property (nonatomic, strong, readonly) NSData *vectorData;
@property (nonatomic) NSUInteger accessCount;
@property (nonatomic) NSTimeInterval lastAccessedTimestamp;  // timeIntervalSinceReferenceDate; 0.0 = never
@property (nonatomic) NSTimeInterval creationTimestamp;      // timeIntervalSinceReferenceDate

- (instancetype)initWithVectorData:(NSData *)vectorData
                       accessCount:(NSUInteger)accessCount
              lastAccessedTimestamp:(NSTimeInterval)lastAccessedTimestamp
                 creationTimestamp:(NSTimeInterval)creationTimestamp;

@end

NS_ASSUME_NONNULL_END
