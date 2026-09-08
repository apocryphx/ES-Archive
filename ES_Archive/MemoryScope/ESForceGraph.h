//
//  ESForceGraph.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Threading model (first cut of the decoupled simulation):
//
//  - The node/edge structure and every ESGraphNode property are owned by the
//    main thread. Drawing, hit testing, bounding rects, and the data source's
//    mutations all read and write them on main, exactly as before.
//  - The physics runs on a private serial queue over plain C buffers that are
//    a snapshot of the structure. It never touches ESGraphNode objects.
//  - After each step the simulation publishes its positions back to main,
//    which copies them into node.position/velocity. A generation counter
//    drops publishes that belong to a structure that has since changed.
//  - Structural edits (add/remove nodes or edges, removeAll, position seeds,
//    alpha nudges) mark the snapshot dirty; the next startSimulation re-syncs.
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
@property (nonatomic) CGFloat flashIntensity;   // [0.0, 1.0], decays each frame

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

/// Simulation energy [0,1]. The getter returns the last published value;
/// setting it (an alpha nudge) reheats the background simulation.
@property (nonatomic) CGFloat alpha;

- (void)addNode:(ESGraphNode *)node;
- (void)removeNode:(ESGraphNode *)node;
- (void)addEdge:(ESGraphEdge *)edge;
- (void)removeEdge:(ESGraphEdge *)edge;
- (void)removeAllNodesAndEdges;

/// Mark the simulation snapshot stale after editing node state directly
/// (position seeds, pinned, visible). add/remove already do this.
- (void)setNeedsStructureSync;

/// Start (or resume) the background simulation. Syncs the structure snapshot
/// if it is dirty. Safe to call repeatedly. Main thread only.
- (void)startSimulation;

/// Stop the background simulation. Positions already published stay put.
- (void)stopSimulation;

/// YES while the background step timer is armed.
@property (nonatomic, readonly) BOOL isRunning;

/// Per-frame main-thread housekeeping that is not physics: decays node flash.
/// Call from the redraw timer.
- (void)decayFlash;

/// YES when the published alpha has decayed below threshold, positions have
/// stopped moving, and no node is flashing.
@property (nonatomic, readonly) BOOL isSettled;

/// Hit test: find node nearest to point within radius.
- (nullable ESGraphNode *)nodeAtPoint:(CGPoint)point radius:(CGFloat)r;

/// Bounding rect of all visible nodes (for auto-fit).
@property (nonatomic, readonly) CGRect boundingRect;

@end

NS_ASSUME_NONNULL_END
