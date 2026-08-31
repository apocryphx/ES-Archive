//
//  ESMemoryScopeDataSource.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class ESForceGraph, ESGraphNode;

/// Posted after any graph mutation (delta or full rebuild).
/// Observers should restart simulation if needed.
extern NSNotificationName const ESGraphDidUpdateNotification;

/// Bridges Core Data (CDMemory + CDLink) into an ESForceGraph.
/// Uses NSFetchedResultsController for live delta updates.
@interface ESMemoryScopeDataSource : NSObject

@property (nonatomic, strong, readonly) ESForceGraph *graph;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSManagedObjectID *, ESGraphNode *> *nodeMap;

/// The persona (author) currently scoping the graph. nil = All (witness) mode:
/// every persona's memories together, colored by author, cross-persona
/// similarity edges allowed. A non-nil value shows one persona's archive with
/// similarity computed only within that persona — the boundary each persona
/// actually experiences.
@property (nonatomic, copy, readonly, nullable) NSString *selectedPersona;

/// Re-scope to a persona (nil = All / witness) and rebuild the graph.
- (void)selectPersona:(nullable NSString *)persona;

/// Rebuild the graph from scratch. Called at launch, explicit refresh,
/// or automatically when a delta batch exceeds the fallback threshold.
- (void)buildGraph;

/// Fetch full memory detail for a selected node.
- (NSDictionary *)memoryDetailForNode:(ESGraphNode *)node;

/// Resolve a node's current title live from Core Data (by object ID), so it
/// always reflects the latest edit without the graph caching a stale copy.
- (NSString *)titleForNode:(ESGraphNode *)node;

@end
