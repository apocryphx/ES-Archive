//
//  ESGraphBuilder.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Background construction of the Archive Scope graph. The main thread only
//  ever receives plain value objects (object IDs, scores) and turns them into
//  ESGraphNode / ESGraphEdge at its own pace:
//
//    1. Core Data snapshot on a private background context: memories in
//       scope, links, and the memory -> active-vector map. Dictionary fetches
//       only; no managed objects cross threads.
//    2. Nodes and explicit link edges are delivered first, so the graph is
//       visible immediately.
//    3. Similarity edges (one nearest neighbor per memory) are computed on the
//       vector cache snapshot with blocked matrix products and delivered in
//       batches as they complete.
//    4. Islands are bridged to the giant component, then `done` fires.
//
//  Cancel at any time; no callback fires after cancel. Every callback runs
//  on the main queue.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESGraphBuildNode : NSObject
@property (nonatomic, strong) NSManagedObjectID *memoryID;
@property (nonatomic, copy, nullable) NSString *author;
@property (nonatomic) int64_t accessCount;
@property (nonatomic, strong, nullable) NSManagedObjectID *vectorID;   // active-embedder vector, if any
@end

@interface ESGraphBuildEdge : NSObject
@property (nonatomic, strong) NSManagedObjectID *sourceID;
@property (nonatomic, strong) NSManagedObjectID *targetID;
@property (nonatomic) float score;
@property (nonatomic) BOOL isExplicitLink;
@end

typedef void (^ESGraphBuilderNodesBlock)(NSArray<ESGraphBuildNode *> *nodes,
                                         NSArray<ESGraphBuildEdge *> *links,
                                         int64_t maxAccessCount);
typedef void (^ESGraphBuilderEdgesBlock)(NSArray<ESGraphBuildEdge *> *edges);
typedef void (^ESGraphBuilderDoneBlock)(void);

@interface ESGraphBuilder : NSObject

/// persona nil = All (witness): every memory, cross-persona neighbors allowed.
- (instancetype)initWithPersona:(nullable NSString *)persona;

@property (atomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;

- (void)startWithNodes:(ESGraphBuilderNodesBlock)onNodes
                 edges:(ESGraphBuilderEdgesBlock)onEdges
                  done:(ESGraphBuilderDoneBlock)onDone;

@end

NS_ASSUME_NONNULL_END
