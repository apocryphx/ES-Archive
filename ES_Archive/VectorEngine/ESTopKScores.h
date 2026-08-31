//
//  TopKScores.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@interface ESTopKScores : NSObject
- (instancetype)initWithCapacity:(NSUInteger)k;

/// Add a candidate. Ranking is by `score` (typically decayed cosine);
/// `cosine` is the pre-decay value carried alongside so callers that want
/// an absolute similarity threshold can apply it without re-computing.
/// When there's no separate decay (pure-cosine search), pass score==cosine.
- (void)addScore:(float)score
          cosine:(float)cosine
     forObjectID:(NSManagedObjectID *)objectID;

/// Convenience: addScore:cosine:forObjectID: with cosine == score.
- (void)addScore:(float)score forObjectID:(NSManagedObjectID *)objectID;

- (NSArray<NSManagedObjectID *> *)topObjectIDs;
- (NSArray<NSDictionary *> *)topEntries;
@end
