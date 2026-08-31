//
//  ESForceGraph.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

@import Foundation;
@import CoreData;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Graph Node

@interface ESGraphNode : NSObject

@property (nonatomic, strong) NSManagedObjectID *memoryID;
@property (nonatomic, copy, nullable) NSString *author;  // persona; drives color in All (witness) mode
@property (nonatomic) CGPoint position;
@property (nonatomic) CGPoint velocity;
@property (nonatomic) CGFloat heat;             // normalized accessCount [0,1]
@property (nonatomic) NSUInteger connectionCount;
@property (nonatomic) BOOL settled;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL pinned;              // fixed position (ego-centric center)
@property (nonatomic) CGFloat flashIntensity;   // [0.0, 1.0], decays each tick

@end

#pragma mark - Graph Edge

@interface ESGraphEdge : NSObject

@property (nonatomic, weak) ESGraphNode *source;
@property (nonatomic, weak) ESGraphNode *target;
@property (nonatomic) CGFloat weight;           // similarity score or 1.0 for CDLink
@property (nonatomic) BOOL isExplicitLink;      // CDLink = YES, similarity = NO

@end

#pragma mark - Force Graph

@interface ESForceGraph : NSObject

@property (nonatomic, readonly) NSArray<ESGraphNode *> *nodes;
@property (nonatomic, readonly) NSArray<ESGraphEdge *> *edges;
@property (nonatomic, readonly) NSArray<ESGraphNode *> *visibleNodes;
@property (nonatomic, readonly) NSArray<ESGraphEdge *> *visibleEdges;
@property (nonatomic) CGFloat alpha;            // simulation energy [0,1]

- (void)addNode:(ESGraphNode *)node;
- (void)removeNode:(ESGraphNode *)node;
- (void)addEdge:(ESGraphEdge *)edge;
- (void)removeEdge:(ESGraphEdge *)edge;
- (void)removeAllNodesAndEdges;

/// Run one simulation step.
- (void)tick;

/// YES when alpha has decayed below threshold.
@property (nonatomic, readonly) BOOL isSettled;

/// Hit test: find node nearest to point within radius.
- (nullable ESGraphNode *)nodeAtPoint:(CGPoint)point radius:(CGFloat)r;

/// Bounding rect of all visible nodes (for auto-fit).
@property (nonatomic, readonly) CGRect boundingRect;

@end

NS_ASSUME_NONNULL_END
