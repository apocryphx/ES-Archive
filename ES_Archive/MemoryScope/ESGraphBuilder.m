//
//  ESGraphBuilder.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESGraphBuilder.h"
#import "ESCoreDataStack.h"
#import "ESVectorEngine.h"
#import "ESVectorCacheEntry.h"
#import "ESLog.h"
#import <Accelerate/Accelerate.h>

// Rows of the query block per matrix product. 256 rows x 70K columns x 4 bytes
// keeps the score block around 70 MB for the largest persona seen so far.
static const NSUInteger kSimilarityBlockRows = 256;
// Similarity edges are delivered to main in batches of this many.
static const NSUInteger kEdgeBatchSize = 2000;

@implementation ESGraphBuildNode
@end

@implementation ESGraphBuildEdge
@end

@interface ESGraphBuilder ()
@property (nonatomic, copy, nullable) NSString *persona;
@property (atomic, assign, getter=isCancelled) BOOL cancelled;
@end

@implementation ESGraphBuilder

- (instancetype)initWithPersona:(NSString *)persona {
    self = [super init];
    if (self) {
        _persona = [persona copy];
    }
    return self;
}

- (void)cancel {
    self.cancelled = YES;
}

#pragma mark - Main-queue delivery

- (void)deliver:(dispatch_block_t)block {
    if (self.cancelled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        block();
    });
}

#pragma mark - Phase 1: Core Data snapshot (background context)

- (void)startWithNodes:(ESGraphBuilderNodesBlock)onNodes
                 edges:(ESGraphBuilderEdgesBlock)onEdges
                  done:(ESGraphBuilderDoneBlock)onDone {
    NSString *persona = self.persona;
    NSString *activeEmbedderID = [ESVectorEngine summaryEmbedder].identifier;

    NSManagedObjectContext *ctx = [[ESCoreDataStack shared].persistentContainer newBackgroundContext];
    [ctx performBlock:^{
        if (self.cancelled) return;

        NSExpressionDescription *oid = [NSExpressionDescription new];
        oid.name = @"oid";
        oid.expression = [NSExpression expressionForEvaluatedObject];
        oid.expressionResultType = NSObjectIDAttributeType;

        // Memories in scope: id, author, accessCount.
        NSFetchRequest *memReq = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        memReq.includesSubentities = NO;
        memReq.resultType = NSDictionaryResultType;
        memReq.propertiesToFetch = @[oid, @"author", @"accessCount"];
        memReq.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:NO]];
        if (persona) memReq.predicate = [NSPredicate predicateWithFormat:@"author == %@", persona];
        NSArray<NSDictionary *> *memRows = [ctx executeFetchRequest:memReq error:nil] ?: @[];

        // Explicit links: source/target ids. (Unscoped, like the link FRC;
        // links whose endpoints are outside the scope are dropped on main.)
        NSFetchRequest *linkReq = [NSFetchRequest fetchRequestWithEntityName:@"CDLink"];
        linkReq.resultType = NSDictionaryResultType;
        linkReq.propertiesToFetch = @[@"sourceMemory", @"targetMemory"];
        NSArray<NSDictionary *> *linkRows = [ctx executeFetchRequest:linkReq error:nil] ?: @[];

        // memory id -> active-embedder vector id, for the scope.
        NSMutableDictionary<NSManagedObjectID *, NSManagedObjectID *> *vectorByMemory = [NSMutableDictionary dictionary];
        if (activeEmbedderID) {
            NSFetchRequest *vecReq = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
            vecReq.resultType = NSDictionaryResultType;
            vecReq.propertiesToFetch = @[oid, @"memory"];
            vecReq.predicate = persona
                ? [NSPredicate predicateWithFormat:@"embedder.identifier == %@ AND memory.author == %@", activeEmbedderID, persona]
                : [NSPredicate predicateWithFormat:@"embedder.identifier == %@", activeEmbedderID];
            for (NSDictionary *row in ([ctx executeFetchRequest:vecReq error:nil] ?: @[])) {
                NSManagedObjectID *m = row[@"memory"];
                NSManagedObjectID *v = row[@"oid"];
                if (m && v) vectorByMemory[m] = v;
            }
        }

        NSMutableArray<ESGraphBuildNode *> *nodes = [NSMutableArray arrayWithCapacity:memRows.count];
        int64_t maxAccess = 1;
        for (NSDictionary *row in memRows) {
            ESGraphBuildNode *n = [ESGraphBuildNode new];
            n.memoryID = row[@"oid"];
            n.author = row[@"author"];
            n.accessCount = [row[@"accessCount"] longLongValue];
            n.vectorID = vectorByMemory[n.memoryID];
            if (n.accessCount > maxAccess) maxAccess = n.accessCount;
            [nodes addObject:n];
        }
        NSMutableArray<ESGraphBuildEdge *> *links = [NSMutableArray arrayWithCapacity:linkRows.count];
        for (NSDictionary *row in linkRows) {
            NSManagedObjectID *s = row[@"sourceMemory"], *t = row[@"targetMemory"];
            if (!s || !t) continue;
            ESGraphBuildEdge *e = [ESGraphBuildEdge new];
            e.sourceID = s; e.targetID = t; e.score = 1.0f; e.isExplicitLink = YES;
            [links addObject:e];
        }

        ESLog(@"[GraphBuilder] snapshot: %lu memories, %lu links, %lu vectors (%@)",
              (unsigned long)nodes.count, (unsigned long)links.count,
              (unsigned long)vectorByMemory.count, persona ?: @"All");

        [self deliver:^{ onNodes(nodes, links, maxAccess); }];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self computeSimilarityForNodes:nodes links:links edges:onEdges done:onDone];
        });
    }];
}

#pragma mark - Phase 2: similarity edges on the vector cache snapshot

- (void)computeSimilarityForNodes:(NSArray<ESGraphBuildNode *> *)nodes
                            links:(NSArray<ESGraphBuildEdge *> *)links
                            edges:(ESGraphBuilderEdgesBlock)onEdges
                             done:(ESGraphBuilderDoneBlock)onDone {
    if (self.cancelled) return;

    ESVectorEngine *engine = [ESVectorEngine shared];
    NSDictionary<NSManagedObjectID *, ESVectorCacheEntry *> *snapshot = [engine cacheSnapshot];
    NSUInteger dim = [engine cacheDimension];

    // Rows of the matrix: every node whose vector is in the cache, in node order.
    NSMutableArray<NSNumber *> *rowNodeIndex = [NSMutableArray arrayWithCapacity:nodes.count];
    for (NSUInteger i = 0; i < nodes.count; i++) {
        ESGraphBuildNode *n = nodes[i];
        if (!n.vectorID) continue;
        ESVectorCacheEntry *entry = snapshot[n.vectorID];
        if (!entry || entry.vectorData.length != dim * sizeof(float)) continue;
        [rowNodeIndex addObject:@(i)];
    }
    NSUInteger n = rowNodeIndex.count;
    if (n < 2 || dim == 0) {
        [self deliver:^{ onDone(); }];
        return;
    }

    float *matrix = malloc(n * dim * sizeof(float));
    if (!matrix) { [self deliver:^{ onDone(); }]; return; }
    for (NSUInteger r = 0; r < n; r++) {
        ESGraphBuildNode *node = nodes[rowNodeIndex[r].unsignedIntegerValue];
        memcpy(matrix + r * dim, snapshot[node.vectorID].vectorData.bytes, dim * sizeof(float));
    }
    snapshot = nil;   // release the entries; the matrix is all we need now

    // neighbor[r] = row index of the nearest other row, or NSNotFound.
    NSUInteger *neighbor = malloc(n * sizeof(NSUInteger));
    float *neighborScore = malloc(n * sizeof(float));
    float *block = malloc(kSimilarityBlockRows * n * sizeof(float));
    if (!neighbor || !neighborScore || !block) {
        free(matrix); free(neighbor); free(neighborScore); free(block);
        [self deliver:^{ onDone(); }];
        return;
    }

    NSDate *t0 = [NSDate date];
    NSMutableArray<ESGraphBuildEdge *> *batch = [NSMutableArray arrayWithCapacity:kEdgeBatchSize];
    for (NSUInteger r0 = 0; r0 < n; r0 += kSimilarityBlockRows) {
        if (self.cancelled) break;
        NSUInteger rows = MIN(kSimilarityBlockRows, n - r0);

        // block[rows x n] = Q[rows x dim] * M^T[dim x n]  (vectors are unit length, so this is cosine)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    (int)rows, (int)n, (int)dim, 1.0f,
                    matrix + r0 * dim, (int)dim,
                    matrix, (int)dim,
                    0.0f, block, (int)n);

        for (NSUInteger i = 0; i < rows; i++) {
            NSUInteger r = r0 + i;
            float *scores = block + i * n;
            scores[r] = -2.0f;                      // exclude self
            vDSP_Length best = 0; float bestScore = 0;
            vDSP_maxvi(scores, 1, &bestScore, &best, n);
            neighbor[r] = best;
            neighborScore[r] = bestScore;

            ESGraphBuildEdge *e = [ESGraphBuildEdge new];
            e.sourceID = nodes[rowNodeIndex[r].unsignedIntegerValue].memoryID;
            e.targetID = nodes[rowNodeIndex[best].unsignedIntegerValue].memoryID;
            e.score = bestScore;
            e.isExplicitLink = NO;
            [batch addObject:e];
        }
        if (batch.count >= kEdgeBatchSize || r0 + rows >= n) {
            NSArray *out = [batch copy];
            [batch removeAllObjects];
            [self deliver:^{ onEdges(out); }];
        }
    }
    free(block);
    ESLog(@"[GraphBuilder] similarity: %lu rows x %lu dims in %.1fs%@",
          (unsigned long)n, (unsigned long)dim, -[t0 timeIntervalSinceNow],
          self.cancelled ? @" (cancelled)" : @"");

    if (!self.cancelled) {
        [self bridgeIslandsWithNodes:nodes rowNodeIndex:rowNodeIndex matrix:matrix dim:dim
                            neighbor:neighbor links:links edges:onEdges];
    }
    free(matrix); free(neighbor); free(neighborScore);
    [self deliver:^{ onDone(); }];
}

#pragma mark - Phase 3: bridge islands to the giant component

// Same rule as the delta path's bridgeIslandsToGiantWithEngine:context:: find
// connected components over links + similarity edges, take the largest as the
// giant, and attach every other component with the single strongest
// member -> giant edge. Done here on index arrays so main never pays for it.
- (void)bridgeIslandsWithNodes:(NSArray<ESGraphBuildNode *> *)nodes
                  rowNodeIndex:(NSArray<NSNumber *> *)rowNodeIndex
                        matrix:(const float *)matrix
                           dim:(NSUInteger)dim
                      neighbor:(const NSUInteger *)neighbor
                         links:(NSArray<ESGraphBuildEdge *> *)links
                         edges:(ESGraphBuilderEdgesBlock)onEdges {
    NSUInteger nodeCount = nodes.count;
    NSUInteger n = rowNodeIndex.count;
    if (nodeCount < 2) return;

    // Union-find over node indices.
    NSUInteger *parent = malloc(nodeCount * sizeof(NSUInteger));
    if (!parent) return;
    for (NSUInteger i = 0; i < nodeCount; i++) parent[i] = i;
    NSUInteger (^find)(NSUInteger) = ^NSUInteger(NSUInteger x) {
        while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
        return x;
    };
    void (^unite)(NSUInteger, NSUInteger) = ^(NSUInteger a, NSUInteger b) {
        NSUInteger ra = find(a), rb = find(b);
        if (ra != rb) parent[ra] = rb;
    };

    NSMutableDictionary<NSManagedObjectID *, NSNumber *> *indexOfMemory = [NSMutableDictionary dictionaryWithCapacity:nodeCount];
    for (NSUInteger i = 0; i < nodeCount; i++) indexOfMemory[nodes[i].memoryID] = @(i);
    for (ESGraphBuildEdge *l in links) {
        NSNumber *a = indexOfMemory[l.sourceID], *b = indexOfMemory[l.targetID];
        if (a && b) unite(a.unsignedIntegerValue, b.unsignedIntegerValue);
    }
    for (NSUInteger r = 0; r < n; r++) {
        if (neighbor[r] == NSNotFound) continue;
        unite(rowNodeIndex[r].unsignedIntegerValue, rowNodeIndex[neighbor[r]].unsignedIntegerValue);
    }

    // Component sizes; giant = largest.
    NSMutableDictionary<NSNumber *, NSNumber *> *sizes = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < nodeCount; i++) {
        NSNumber *root = @(find(i));
        sizes[root] = @(sizes[root].unsignedIntegerValue + 1);
    }
    if (sizes.count < 2) { free(parent); return; }
    NSUInteger giantRoot = 0, giantSize = 0;
    for (NSNumber *root in sizes) {
        if (sizes[root].unsignedIntegerValue > giantSize) {
            giantSize = sizes[root].unsignedIntegerValue; giantRoot = root.unsignedIntegerValue;
        }
    }

    // Rows split by membership: giant columns vs island rows (per island).
    NSMutableArray<NSNumber *> *giantRows = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *islandRows = [NSMutableDictionary dictionary];
    for (NSUInteger r = 0; r < n; r++) {
        NSUInteger root = find(rowNodeIndex[r].unsignedIntegerValue);
        if (root == giantRoot) { [giantRows addObject:@(r)]; continue; }
        NSMutableArray *rows = islandRows[@(root)];
        if (!rows) { rows = [NSMutableArray array]; islandRows[@(root)] = rows; }
        [rows addObject:@(r)];
    }
    NSUInteger g = giantRows.count;
    if (g == 0 || islandRows.count == 0) { free(parent); return; }

    // Gather the giant's vectors once; islands are scored against it in one
    // product per island (islands are small, so blocks stay small).
    float *giantMatrix = malloc(g * dim * sizeof(float));
    if (!giantMatrix) { free(parent); return; }
    for (NSUInteger k = 0; k < g; k++) {
        memcpy(giantMatrix + k * dim, matrix + giantRows[k].unsignedIntegerValue * dim, dim * sizeof(float));
    }

    NSMutableArray<ESGraphBuildEdge *> *bridges = [NSMutableArray arrayWithCapacity:islandRows.count];
    NSUInteger bridged = 0;
    for (NSNumber *root in islandRows) {
        if (self.cancelled) break;
        NSArray<NSNumber *> *rows = islandRows[root];
        NSUInteger m = rows.count;
        float *q = malloc(m * dim * sizeof(float));
        float *scores = malloc(m * g * sizeof(float));
        if (!q || !scores) { free(q); free(scores); continue; }
        for (NSUInteger i = 0; i < m; i++) {
            memcpy(q + i * dim, matrix + rows[i].unsignedIntegerValue * dim, dim * sizeof(float));
        }
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    (int)m, (int)g, (int)dim, 1.0f, q, (int)dim, giantMatrix, (int)dim, 0.0f, scores, (int)g);
        vDSP_Length best = 0; float bestScore = 0;
        vDSP_maxvi(scores, 1, &bestScore, &best, m * g);
        NSUInteger srcRow = rows[best / g].unsignedIntegerValue;
        NSUInteger tgtRow = giantRows[best % g].unsignedIntegerValue;
        free(q); free(scores);

        ESGraphBuildEdge *e = [ESGraphBuildEdge new];
        e.sourceID = nodes[rowNodeIndex[srcRow].unsignedIntegerValue].memoryID;
        e.targetID = nodes[rowNodeIndex[tgtRow].unsignedIntegerValue].memoryID;
        e.score = bestScore;
        e.isExplicitLink = NO;
        [bridges addObject:e];
        bridged++;
    }
    free(giantMatrix); free(parent);

    ESLog(@"[GraphBuilder] bridged %lu island(s) to a giant of %lu", (unsigned long)bridged, (unsigned long)giantSize);
    if (bridges.count > 0) {
        NSArray *out = [bridges copy];
        [self deliver:^{ onEdges(out); }];
    }
}

@end
