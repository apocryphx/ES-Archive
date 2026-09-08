//
//  ESMemoryScopeDataSource.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryScopeDataSource.h"
#import "ESForceGraph.h"
#import "ESGraphBuilder.h"
#import "ESCoreDataStack.h"
#import "ESVectorEngine.h"
#import "ESVectorSearchResult.h"
#import "ESServerConfig.h"
#import "CDMemory.h"
#import "CDVector.h"
#import "CDLink.h"

NSNotificationName const ESGraphDidUpdateNotification = @"ESGraphDidUpdate";

static const NSUInteger kDeltaFallbackThreshold = 20;
static const CGFloat    kAlphaNudgeInsert       = 0.4;
static const CGFloat    kAlphaNudgeDelete        = 0.15;
static const CGFloat    kAlphaNudgeLinkChange   = 0.2;

#pragma mark - ESGraphDeltaBatch

@interface ESGraphDeltaBatch : NSObject
@property (nonatomic, strong) NSMutableArray<NSManagedObjectID *> *insertedMemoryIDs;
@property (nonatomic, strong) NSMutableArray<NSManagedObjectID *> *deletedMemoryIDs;
@property (nonatomic, strong) NSMutableArray<NSManagedObjectID *> *insertedLinkIDs;
@property (nonatomic, strong) NSMutableArray<NSManagedObjectID *> *deletedLinkIDs;
@property (nonatomic, readonly) NSUInteger totalChanges;
@end

@implementation ESGraphDeltaBatch

- (instancetype)init {
    self = [super init];
    if (self) {
        _insertedMemoryIDs = [NSMutableArray array];
        _deletedMemoryIDs  = [NSMutableArray array];
        _insertedLinkIDs   = [NSMutableArray array];
        _deletedLinkIDs    = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)totalChanges {
    return self.insertedMemoryIDs.count
         + self.deletedMemoryIDs.count
         + self.insertedLinkIDs.count
         + self.deletedLinkIDs.count;
}

@end

#pragma mark - ESMemoryScopeDataSource

@interface ESMemoryScopeDataSource () <NSFetchedResultsControllerDelegate>
@property (nonatomic, strong) ESForceGraph *graph;
@property (nonatomic, strong) NSFetchedResultsController *memoryFRC;
@property (nonatomic, strong) NSFetchedResultsController *linkFRC;
@property (nonatomic, strong) NSMutableDictionary<NSManagedObjectID *, ESGraphNode *> *nodeMap;
@property (nonatomic, strong) ESGraphDeltaBatch *pendingDeltaBatch;
@property (nonatomic, copy, nullable) NSString *selectedPersona;  // nil = All (witness)
// Vector IDs of the current persona's memories, for scoping similarity to
// within-persona. nil in All mode (unscoped, cross-persona edges allowed).
// Recomputed per buildGraph.
@property (nonatomic, strong, nullable) NSSet<NSManagedObjectID *> *allowedVectorIDs;
// In-flight background build, if any. Replaced (and the old one cancelled)
// by every buildGraph; deltas that arrive mid-build schedule a rebuild.
@property (nonatomic, strong, nullable) ESGraphBuilder *builder;
@property (nonatomic) BOOL rebuildPending;
@end

@implementation ESMemoryScopeDataSource

- (instancetype)init {
    self = [super init];
    if (self) {
        _graph   = [[ESForceGraph alloc] init];
        _nodeMap = [NSMutableDictionary dictionary];
        // Default to the first persona alphabetically — one mind at a time, the
        // boundary-respecting view. The picker can switch to another persona or to
        // All (witness). No port→author lookup: the stdio/UDS host has no HTTP port
        // map, and "first persona" is all the initial scope needs.
        _selectedPersona = [self firstArchivePersona];
        [self setupFRCs];
    }
    return self;
}

// The archive's alphabetically-first persona (distinct CDMemory.author), or nil
// when nothing is authored yet — the graph then opens in All (witness) mode. Sorted
// the same way ESMemoryScopeWindowController orders the persona picker, so the
// default selection lands on the picker's first entry.
- (nullable NSString *)firstArchivePersona {
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    req.includesSubentities = NO;
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[@"author"];
    req.returnsDistinctResults = YES;

    NSArray<NSDictionary *> *rows =
        [[ESCoreDataStack shared].viewContext executeFetchRequest:req error:nil] ?: @[];
    NSMutableSet<NSString *> *authors = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *a = row[@"author"];
        if (a.length > 0) [authors addObject:a];
    }
    return [[authors.allObjects
             sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] firstObject];
}

- (void)dealloc {
    [_builder cancel];
}

#pragma mark - FRC Setup

- (void)setupFRCs {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    // Memory FRC — scoped to the selected persona (nil = All / witness).
    NSFetchRequest *memFetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    memFetch.includesSubentities = NO;
    if (self.selectedPersona) {
        memFetch.predicate = [NSPredicate predicateWithFormat:@"author == %@", self.selectedPersona];
    }
    memFetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:NO]];
    self.memoryFRC = [[NSFetchedResultsController alloc] initWithFetchRequest:memFetch
                                                         managedObjectContext:ctx
                                                           sectionNameKeyPath:nil
                                                                    cacheName:nil];
    self.memoryFRC.delegate = self;
    [self.memoryFRC performFetch:nil];

    // Link FRC
    NSFetchRequest *linkFetch = [NSFetchRequest fetchRequestWithEntityName:@"CDLink"];
    linkFetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:NO]];
    self.linkFRC = [[NSFetchedResultsController alloc] initWithFetchRequest:linkFetch
                                                        managedObjectContext:ctx
                                                          sectionNameKeyPath:nil
                                                                   cacheName:nil];
    self.linkFRC.delegate = self;
    [self.linkFRC performFetch:nil];
}

- (void)selectPersona:(nullable NSString *)persona {
    if (persona == self.selectedPersona || [persona isEqualToString:self.selectedPersona]) return;
    self.selectedPersona = persona;

    // Re-scope the FRCs to the new persona, then rebuild. Any pending delta
    // batch is for the old scope — drop it.
    self.pendingDeltaBatch = nil;
    self.memoryFRC.delegate = nil;
    self.linkFRC.delegate = nil;
    [self setupFRCs];
    [self buildGraph];
}

// Nearest neighbors for a memory, scoped to the current persona's vectors
// (unscoped in All / witness mode). limit:2 leaves room to skip the self-hit.
- (NSArray<ESVectorSearchResult *> *)nearestNeighborsForMemory:(CDMemory *)mem
                                                        engine:(ESVectorEngine *)engine {
    if (self.allowedVectorIDs) {
        return [engine similarToMemory:mem limit:2 allowedVectorIDs:self.allowedVectorIDs];
    }
    return [engine similarToMemory:mem limit:2];
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    if (!self.pendingDeltaBatch) {
        self.pendingDeltaBatch = [[ESGraphDeltaBatch alloc] init];
    }
}

- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath {

    NSManagedObject *obj = (NSManagedObject *)anObject;
    NSManagedObjectID *oid = obj.objectID;
    ESGraphDeltaBatch *batch = self.pendingDeltaBatch;
    if (!batch) return;

    BOOL isMemory = [obj.entity.name isEqualToString:@"CDMemory"];
    BOOL isLink   = [obj.entity.name isEqualToString:@"CDLink"];

    switch (type) {
        case NSFetchedResultsChangeInsert:
            if (isMemory)    [batch.insertedMemoryIDs addObject:oid];
            else if (isLink) [batch.insertedLinkIDs addObject:oid];
            break;
        case NSFetchedResultsChangeDelete:
            if (isMemory)    [batch.deletedMemoryIDs addObject:oid];
            else if (isLink) [batch.deletedLinkIDs addObject:oid];
            break;
        case NSFetchedResultsChangeUpdate:
        case NSFetchedResultsChangeMove:
            // Property edits (title, body, accessCount/heat) and re-sorts don't
            // change graph structure, so they must not trigger a redraw. Ignoring
            // them keeps routine memory reads (which bump accessCount) from
            // churning the graph. Structure follows add/delete of nodes and links
            // only; re-embeddings come through ESVectorCacheReadyNotification.
            break;
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    ESGraphDeltaBatch *batch = self.pendingDeltaBatch;
    self.pendingDeltaBatch = nil;
    if (!batch || batch.totalChanges == 0) return;

    // A build is in flight: its snapshot predates this change. Rebuild once it
    // lands rather than patching a graph that is still arriving.
    if (self.builder) {
        self.rebuildPending = YES;
        return;
    }

    if (batch.totalChanges > kDeltaFallbackThreshold) {
        [self buildGraph];
        return;
    }

    [self processDeltaBatch:batch];
}

#pragma mark - Delta Processing

- (void)processDeltaBatch:(ESGraphDeltaBatch *)batch {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    ESVectorEngine *engine = [ESVectorEngine shared];

    // Compute current max access for heat normalization
    int64_t maxAccess = 1;
    for (CDMemory *mem in self.memoryFRC.fetchedObjects) {
        if (mem.accessCount > maxAccess) maxAccess = mem.accessCount;
    }

    // --- Memory Deletes (before inserts, to avoid stale references) ---
    for (NSManagedObjectID *oid in batch.deletedMemoryIDs) {
        ESGraphNode *node = self.nodeMap[oid];
        if (!node) continue;

        // Remove all edges touching this node
        NSArray<ESGraphEdge *> *allEdges = [self.graph.edges copy];
        for (ESGraphEdge *edge in allEdges) {
            if (edge.source == node || edge.target == node) {
                [self.graph removeEdge:edge];
            }
        }

        [self.graph removeNode:node];
        [self.nodeMap removeObjectForKey:oid];
        self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeDelete);
    }

    // --- Memory Inserts ---
    for (NSManagedObjectID *oid in batch.insertedMemoryIDs) {
        CDMemory *mem = (CDMemory *)[ctx objectWithID:oid];
        if (!mem) continue;

        ESGraphNode *node = [[ESGraphNode alloc] init];
        node.memoryID = oid;
        node.author = mem.author;
        node.heat = (CGFloat)mem.accessCount / (CGFloat)maxAccess;
        node.connectionCount = 0;
        node.velocity = CGPointZero;
        node.visible = YES;

        // Position at, and link to, the single nearest neighbor (persona-scoped).
        // The query memory itself can appear in results — skip it and take the
        // first real visible neighbor, keeping that result's score for the edge.
        ESGraphNode *nearest = nil;
        CGFloat nearestScore = 0;
        for (ESVectorSearchResult *r in [self nearestNeighborsForMemory:mem engine:engine]) {
            ESGraphNode *neighbor = self.nodeMap[r.memory.objectID];
            if (neighbor && neighbor != node && neighbor.visible) {
                nearest = neighbor;
                nearestScore = (CGFloat)r.score;
                node.position = neighbor.position;
                break;
            }
        }
        if (!nearest) {
            CGRect bounds = self.graph.boundingRect;
            node.position = CGRectIsEmpty(bounds)
                ? CGPointZero
                : CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        }

        self.nodeMap[oid] = node;
        [self.graph addNode:node];

        // One similarity edge: new node → its nearest neighbor. No dedup.
        if (nearest) {
            ESGraphEdge *edge = [[ESGraphEdge alloc] init];
            edge.source = node;
            edge.target = nearest;
            edge.weight = nearestScore;
            edge.isExplicitLink = NO;
            [self.graph addEdge:edge];
        }

        self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeInsert);
    }

    // --- CDLink Inserts ---
    for (NSManagedObjectID *oid in batch.insertedLinkIDs) {
        CDLink *link = (CDLink *)[ctx objectWithID:oid];
        if (!link || !link.sourceMemory || !link.targetMemory) continue;

        ESGraphNode *src = self.nodeMap[link.sourceMemory.objectID];
        ESGraphNode *tgt = self.nodeMap[link.targetMemory.objectID];
        if (!src || !tgt || src == tgt) continue;

        ESGraphEdge *edge = [[ESGraphEdge alloc] init];
        edge.source = src;
        edge.target = tgt;
        edge.weight = 1.0;
        edge.isExplicitLink = YES;
        [self.graph addEdge:edge];

        src.connectionCount++;
        tgt.connectionCount++;
        self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeLinkChange);
    }


    // Reconcile CDLink deletes: scan explicit edges, remove any without backing CDLink
    if (batch.deletedLinkIDs.count > 0) {
        [self reconcileExplicitEdges];
        self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeLinkChange);
    }

    // Heal orphans left by deletions. Deleting a memory strips every edge that
    // touched it — including the one similarity edge a neighbor had pointing AT
    // it, leaving that neighbor with no edge at all. A full rebuild re-picks a
    // nearest neighbor for such a node; the delta path must too, or deletions
    // slowly accrete disconnected memories (the "there's always one isolated
    // node" drift). Give every now-edgeless node a fresh nearest-neighbor edge.
    if (batch.deletedMemoryIDs.count > 0) {
        NSMutableSet<ESGraphNode *> *connected = [NSMutableSet set];
        for (ESGraphEdge *e in self.graph.edges) {
            if (e.source) [connected addObject:e.source];
            if (e.target) [connected addObject:e.target];
        }
        for (ESGraphNode *node in [self.graph.nodes copy]) {
            if ([connected containsObject:node]) continue;
            CDMemory *mem = (CDMemory *)[ctx objectWithID:node.memoryID];
            if (!mem) continue;
            for (ESVectorSearchResult *r in [self nearestNeighborsForMemory:mem engine:engine]) {
                ESGraphNode *tgt = self.nodeMap[r.memory.objectID];
                if (!tgt || tgt == node) continue;  // skip self and already-deleted neighbors
                ESGraphEdge *edge = [[ESGraphEdge alloc] init];
                edge.source = node;
                edge.target = tgt;
                edge.weight = (CGFloat)r.score;
                edge.isExplicitLink = NO;
                [self.graph addEdge:edge];
                break;  // one edge per memory, same as buildGraph
            }
        }
        // A re-picked nearest neighbor can land the healed node inside an
        // island rather than the giant, so re-bridge afterwards. Idempotent —
        // no-op when the graph is already one connected whole.
        [self bridgeIslandsToGiantWithEngine:engine context:ctx];
        self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeDelete);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:ESGraphDidUpdateNotification
                                                        object:self];
}

#pragma mark - Edge Helpers

- (void)reconcileExplicitEdges {
    NSMutableSet<NSString *> *validPairs = [NSMutableSet set];

    for (CDLink *link in self.linkFRC.fetchedObjects) {
        if (!link.sourceMemory || !link.targetMemory) continue;
        NSString *pairKey = [self pairKeyForA:link.sourceMemory.objectID b:link.targetMemory.objectID];
        [validPairs addObject:pairKey];
    }

    NSArray<ESGraphEdge *> *allEdges = [self.graph.edges copy];
    for (ESGraphEdge *edge in allEdges) {
        if (!edge.isExplicitLink) continue;
        if (!edge.source || !edge.target) {
            [self.graph removeEdge:edge];
            continue;
        }
        NSString *pairKey = [self pairKeyForA:edge.source.memoryID b:edge.target.memoryID];
        if (![validPairs containsObject:pairKey]) {
            edge.source.connectionCount = (edge.source.connectionCount > 0) ? edge.source.connectionCount - 1 : 0;
            edge.target.connectionCount = (edge.target.connectionCount > 0) ? edge.target.connectionCount - 1 : 0;
            [self.graph removeEdge:edge];
        }
    }
}

#pragma mark - Build Graph (Cold Load)

- (BOOL)isBuilding {
    return self.builder != nil;
}

// The cold build runs off the main thread (see ESGraphBuilder). Main only
// receives value objects and turns them into nodes and edges:
//   1. nodes + explicit links arrive first — the graph is visible at once;
//   2. similarity edges stream in batches as the background pass completes;
//   3. island bridges arrive last, then the build is done.
// Every callback checks that it belongs to the current build.
- (void)buildGraph {
    [self.builder cancel];
    self.rebuildPending = NO;

    [self.graph removeAllNodesAndEdges];
    [self.nodeMap removeAllObjects];
    self.allowedVectorIDs = nil;

    ESGraphBuilder *builder = [[ESGraphBuilder alloc] initWithPersona:self.selectedPersona];
    self.builder = builder;
    __weak typeof(self) weakSelf = self;

    [builder startWithNodes:^(NSArray<ESGraphBuildNode *> *nodes, NSArray<ESGraphBuildEdge *> *links, int64_t maxAccess) {
        typeof(self) self = weakSelf;
        if (!self || self.builder != builder) return;
        [self applyBuildNodes:nodes links:links maxAccess:maxAccess];
    } edges:^(NSArray<ESGraphBuildEdge *> *edges) {
        typeof(self) self = weakSelf;
        if (!self || self.builder != builder) return;
        [self applyBuildEdges:edges];
    } done:^{
        typeof(self) self = weakSelf;
        if (!self || self.builder != builder) return;
        self.builder = nil;
        if (self.rebuildPending) {
            [self buildGraph];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:ESGraphDidUpdateNotification
                                                            object:self];
    }];
}

- (void)applyBuildNodes:(NSArray<ESGraphBuildNode *> *)buildNodes
                  links:(NSArray<ESGraphBuildEdge *> *)links
               maxAccess:(int64_t)maxAccess {
    if (buildNodes.count == 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ESGraphDidUpdateNotification
                                                            object:self];
        return;
    }
    if (maxAccess < 1) maxAccess = 1;

    // Persona scope for the delta path's similarity lookups (nil = All mode).
    NSMutableSet<NSManagedObjectID *> *allowed = self.selectedPersona ? [NSMutableSet setWithCapacity:buildNodes.count] : nil;

    // Link counts drive seed ordering, as before.
    NSCountedSet *linkCounts = [[NSCountedSet alloc] init];
    for (ESGraphBuildEdge *l in links) {
        [linkCounts addObject:l.sourceID];
        [linkCounts addObject:l.targetID];
    }

    // Seed canvas centered on the graph origin, so a fresh graph appears in the
    // middle of the view at any transform and auto-fit only rescales it. A
    // corner-anchored canvas put the cloud in the lower right until the fit
    // caught up.
    CGFloat canvasW = 800, canvasH = 600;
    CGPoint (^randomSeed)(void) = ^CGPoint{
        return CGPointMake(-canvasW * 0.25 + arc4random_uniform((uint32_t)(canvasW * 0.5)),
                           -canvasH * 0.25 + arc4random_uniform((uint32_t)(canvasH * 0.5)));
    };
    NSMutableArray<ESGraphNode *> *seeds = [NSMutableArray array];
    NSMutableArray<ESGraphNode *> *satellites = [NSMutableArray array];

    for (ESGraphBuildNode *b in buildNodes) {
        ESGraphNode *node = [[ESGraphNode alloc] init];
        node.memoryID = b.memoryID;
        node.author = b.author;
        node.heat = (CGFloat)b.accessCount / (CGFloat)maxAccess;
        node.connectionCount = [linkCounts countForObject:b.memoryID];
        node.velocity = CGPointZero;
        node.visible = YES;
        if (allowed && b.vectorID) [allowed addObject:b.vectorID];

        self.nodeMap[b.memoryID] = node;
        [self.graph addNode:node];

        if (node.connectionCount > 0) {
            node.position = randomSeed();
            [seeds addObject:node];
        } else {
            [satellites addObject:node];
        }
    }
    self.allowedVectorIDs = allowed;

    // Satellites start on a seed; the similarity edge that arrives later pulls
    // each one toward its real neighbor. (The synchronous build placed them at
    // the neighbor directly, which is exactly the pass now running in the
    // background.)
    for (ESGraphNode *sat in satellites) {
        sat.position = seeds.count > 0
            ? seeds[arc4random_uniform((uint32_t)seeds.count)].position
            : randomSeed();
    }

    // Explicit link edges (user-authored connections — unlimited).
    for (ESGraphBuildEdge *l in links) {
        ESGraphNode *src = self.nodeMap[l.sourceID];
        ESGraphNode *tgt = self.nodeMap[l.targetID];
        if (!src || !tgt || src == tgt) continue;
        ESGraphEdge *edge = [[ESGraphEdge alloc] init];
        edge.source = src;
        edge.target = tgt;
        edge.weight = 1.0;
        edge.isExplicitLink = YES;
        [self.graph addEdge:edge];
    }

    // Full energy — the only place alpha is set to 1.0.
    self.graph.alpha = 1.0;
    [[NSNotificationCenter defaultCenter] postNotificationName:ESGraphDidUpdateNotification
                                                        object:self];
}

- (void)applyBuildEdges:(NSArray<ESGraphBuildEdge *> *)edges {
    NSUInteger added = 0;
    for (ESGraphBuildEdge *b in edges) {
        ESGraphNode *src = self.nodeMap[b.sourceID];
        ESGraphNode *tgt = self.nodeMap[b.targetID];
        if (!src || !tgt || src == tgt) continue;
        ESGraphEdge *edge = [[ESGraphEdge alloc] init];
        edge.source = src;
        edge.target = tgt;
        edge.weight = b.score;
        edge.isExplicitLink = b.isExplicitLink;
        [self.graph addEdge:edge];
        added++;
    }
    if (added == 0) return;
    // New springs; keep the layout warm enough to follow them.
    self.graph.alpha = fmax(self.graph.alpha, kAlphaNudgeInsert);
    [[NSNotificationCenter defaultCenter] postNotificationName:ESGraphDidUpdateNotification
                                                        object:self];
}

// Connect every disconnected island to the giant component with a single
// bridge edge. The one-edge-per-memory rule leaves ~15% of nodes in small
// pockets that close on themselves; here we detect the connected components,
// take the largest as the giant, and for each remaining component add one edge
// from the island member whose nearest giant node is strongest. Idempotent:
// an already-connected graph has a single component and returns immediately, so
// this is safe to call from both the full build and the delta heal.
- (void)bridgeIslandsToGiantWithEngine:(ESVectorEngine *)engine
                               context:(NSManagedObjectContext *)ctx {
    if (self.graph.nodes.count < 2 || !engine || !ctx) return;

    // Undirected adjacency keyed by node.
    NSMapTable<ESGraphNode *, NSMutableArray<ESGraphNode *> *> *adj =
        [NSMapTable strongToStrongObjectsMapTable];
    for (ESGraphNode *n in self.graph.nodes) {
        [adj setObject:[NSMutableArray array] forKey:n];
    }
    for (ESGraphEdge *e in self.graph.edges) {
        if (!e.source || !e.target) continue;
        [[adj objectForKey:e.source] addObject:e.target];
        [[adj objectForKey:e.target] addObject:e.source];
    }

    // Connected components via iterative DFS.
    NSMutableSet<ESGraphNode *> *seen = [NSMutableSet set];
    NSMutableArray<NSArray<ESGraphNode *> *> *components = [NSMutableArray array];
    for (ESGraphNode *start in self.graph.nodes) {
        if ([seen containsObject:start]) continue;
        NSMutableArray<ESGraphNode *> *comp = [NSMutableArray array];
        NSMutableArray<ESGraphNode *> *stack = [NSMutableArray arrayWithObject:start];
        [seen addObject:start];
        while (stack.count) {
            ESGraphNode *cur = stack.lastObject;
            [stack removeLastObject];
            [comp addObject:cur];
            for (ESGraphNode *nb in [adj objectForKey:cur]) {
                if (![seen containsObject:nb]) { [seen addObject:nb]; [stack addObject:nb]; }
            }
        }
        [components addObject:comp];
    }
    if (components.count < 2) return;  // already one connected whole

    // Giant = largest component.
    NSArray<ESGraphNode *> *giant = components.firstObject;
    for (NSArray<ESGraphNode *> *c in components) {
        if (c.count > giant.count) giant = c;
    }

    // Vector IDs of the giant's members, to scope each bridge search so the
    // island can only attach to the giant (never to another island).
    NSMutableSet<NSManagedObjectID *> *giantVectorIDs = [NSMutableSet set];
    for (ESGraphNode *n in giant) {
        CDMemory *m = (CDMemory *)[ctx objectWithID:n.memoryID];
        CDVector *v = [m vectorForActiveEmbedder];
        if (v) [giantVectorIDs addObject:v.objectID];
    }
    if (giantVectorIDs.count == 0) return;

    // Bridge each non-giant component with a single edge: across its members,
    // the one whose nearest giant node scores highest becomes the anchor.
    for (NSArray<ESGraphNode *> *comp in components) {
        if (comp == giant) continue;

        ESGraphNode *bestSrc = nil, *bestTgt = nil;
        double bestScore = -1.0;
        for (ESGraphNode *member in comp) {
            CDMemory *mem = (CDMemory *)[ctx objectWithID:member.memoryID];
            NSArray<ESVectorSearchResult *> *hits =
                [engine similarToMemory:mem limit:1 allowedVectorIDs:giantVectorIDs];
            for (ESVectorSearchResult *r in hits) {
                ESGraphNode *tgt = self.nodeMap[r.memory.objectID];
                if (!tgt) continue;
                if (r.score > bestScore) { bestScore = r.score; bestSrc = member; bestTgt = tgt; }
                break;
            }
        }
        if (bestSrc && bestTgt) {
            ESGraphEdge *edge = [[ESGraphEdge alloc] init];
            edge.source = bestSrc;
            edge.target = bestTgt;
            edge.weight = (CGFloat)bestScore;
            edge.isExplicitLink = NO;
            [self.graph addEdge:edge];
        }
    }
}

#pragma mark - Helpers

- (NSString *)pairKeyForA:(NSManagedObjectID *)a b:(NSManagedObjectID *)b {
    NSString *sa = a.URIRepresentation.absoluteString;
    NSString *sb = b.URIRepresentation.absoluteString;
    if ([sa compare:sb] == NSOrderedDescending) {
        return [NSString stringWithFormat:@"%@|%@", sb, sa];
    }
    return [NSString stringWithFormat:@"%@|%@", sa, sb];
}

#pragma mark - Detail

- (NSDictionary *)memoryDetailForNode:(ESGraphNode *)node {
    if (!node || !node.memoryID) return @{};

    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    CDMemory *mem = (CDMemory *)[ctx objectWithID:node.memoryID];
    if (!mem || mem.isFault) {
        [ctx refreshObject:mem mergeChanges:YES];
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";

    NSMutableDictionary *detail = [NSMutableDictionary dictionary];
    detail[@"title"] = mem.title ?: @"Untitled";
    detail[@"body"] = mem.body ?: @"";
    detail[@"type"] = mem.type ?: @"memory";
    detail[@"accessCount"] = @(mem.accessCount);
    if (mem.dateCreated) detail[@"dateCreated"] = [fmt stringFromDate:mem.dateCreated];
    if (mem.dateModified) detail[@"dateModified"] = [fmt stringFromDate:mem.dateModified];
    if (mem.author) detail[@"author"] = mem.author;

    // Marginalia (comments) — sorted oldest first
    NSSet *marginalia = mem.marginalia;
    if (marginalia.count > 0) {
        NSSortDescriptor *byDate = [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES];
        NSArray *sorted = [marginalia sortedArrayUsingDescriptors:@[byDate]];
        NSMutableArray *comments = [NSMutableArray arrayWithCapacity:sorted.count];
        for (NSManagedObject *m in sorted) {
            NSMutableDictionary *c = [NSMutableDictionary dictionary];
            c[@"body"] = [m valueForKey:@"body"] ?: @"";
            if ([m valueForKey:@"author"]) c[@"author"] = [m valueForKey:@"author"];
            NSDate *d = [m valueForKey:@"dateCreated"];
            if (d) c[@"date"] = [fmt stringFromDate:d];
            [comments addObject:c];
        }
        detail[@"comments"] = comments;
    }

    return detail;
}

- (NSString *)titleForNode:(ESGraphNode *)node {
    if (!node || !node.memoryID) return @"Untitled";

    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    CDMemory *mem = (CDMemory *)[ctx objectWithID:node.memoryID];
    return mem.title ?: @"Untitled";
}

@end
