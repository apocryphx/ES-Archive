//
//  ESForceGraph.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESForceGraph.h"
#import <math.h>

// Force simulation constants
static const CGFloat kRepulsionStrength   = 500.0;
static const CGFloat kRepulsionMaxDist    = 300.0;
static const CGFloat kSpringStrength      = 0.02;
static const CGFloat kLinkRestLength      = 60.0;   // CDLink edges (tight)
static const CGFloat kSimilarityRestLength = 120.0;  // similarity edges (loose)
static const CGFloat kCenterGravity       = 0.01;
static const CGFloat kDamping             = 0.9;
static const CGFloat kAlphaDecay          = 0.995;
static const CGFloat kAlphaMin            = 0.001;
static const CGFloat kMaxVelocity         = 15.0;
static const CGFloat kSettleDelta         = 0.1;  // max position delta (η) to consider settled
static const CGFloat kFlashDecay          = 0.88; // ~18 frames to fade at 60fps
static const uint64_t kStepIntervalNsec   = NSEC_PER_SEC / 60;

#pragma mark - ESGraphNode

@implementation ESGraphNode
@end

#pragma mark - ESGraphEdge

@implementation ESGraphEdge
@end

#pragma mark - Simulation snapshot

/// Plain buffers the physics runs over. Built on main from the node/edge
/// objects, then owned by the simulation queue. Never shared while mutable.
@interface ESSimState : NSObject {
@public
    NSUInteger  count;
    CGPoint    *pos;
    CGPoint    *vel;
    BOOL       *pinned;
    BOOL       *visible;
    NSUInteger  edgeCount;
    NSUInteger *edgeA;
    NSUInteger *edgeB;
    BOOL       *edgeExplicit;
    NSUInteger  generation;
}
@end

@implementation ESSimState
- (void)dealloc {
    free(pos); free(vel); free(pinned); free(visible);
    free(edgeA); free(edgeB); free(edgeExplicit);
}
@end

#pragma mark - ESForceGraph

@implementation ESForceGraph {
    // Main-thread owned structure.
    NSMutableArray<ESGraphNode *> *_nodes;
    NSMutableArray<ESGraphEdge *> *_edges;
    BOOL _structureDirty;
    NSUInteger _generation;          // bumped on every structure sync

    // Last values published by the simulation (main-thread reads).
    CGFloat _publishedAlpha;
    CGFloat _publishedMaxDelta;

    // Simulation queue state. Touched only on _simQueue.
    dispatch_queue_t _simQueue;
    dispatch_source_t _stepTimer;
    ESSimState *_sim;
    CGFloat _simAlpha;
    CGFloat _simMaxDelta;
    BOOL _running;                   // main-thread view of the timer state
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodes = [NSMutableArray array];
        _edges = [NSMutableArray array];
        _publishedAlpha = 1.0;
        _publishedMaxDelta = CGFLOAT_MAX;   // force at least one step before settling
        _simAlpha = 1.0;
        _simMaxDelta = CGFLOAT_MAX;
        _structureDirty = YES;
        _simQueue = dispatch_queue_create("com.esarchive.forcegraph.simulation", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_stepTimer) dispatch_source_cancel(_stepTimer);
}

- (NSArray<ESGraphNode *> *)nodes { return _nodes; }
- (NSArray<ESGraphEdge *> *)edges { return _edges; }

#pragma mark - Structure (main thread)

- (void)addNode:(ESGraphNode *)node {
    [_nodes addObject:node];
    _structureDirty = YES;
}

- (void)removeNode:(ESGraphNode *)node {
    [_nodes removeObject:node];
    _structureDirty = YES;
}

- (void)addEdge:(ESGraphEdge *)edge {
    [_edges addObject:edge];
    _structureDirty = YES;
}

- (void)removeEdge:(ESGraphEdge *)edge {
    [_edges removeObject:edge];
    _structureDirty = YES;
}

- (void)removeAllNodesAndEdges {
    [_nodes removeAllObjects];
    [_edges removeAllObjects];
    _structureDirty = YES;
    self.alpha = 1.0;
}

- (void)setNeedsStructureSync {
    _structureDirty = YES;
}

#pragma mark - Alpha

- (CGFloat)alpha {
    return _publishedAlpha;
}

- (void)setAlpha:(CGFloat)alpha {
    _publishedAlpha = alpha;
    _publishedMaxDelta = CGFLOAT_MAX;       // not settled until the sim says so
    dispatch_async(_simQueue, ^{
        self->_simAlpha = alpha;
        self->_simMaxDelta = CGFLOAT_MAX;
    });
    if (_running) [self armStepTimer];       // reheat an idle simulation
}

#pragma mark - Visible Subsets

- (NSArray<ESGraphNode *> *)visibleNodes {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:_nodes.count];
    for (ESGraphNode *n in _nodes) {
        if (n.visible) [result addObject:n];
    }
    return result;
}

- (NSArray<ESGraphEdge *> *)visibleEdges {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:_edges.count];
    for (ESGraphEdge *e in _edges) {
        if (e.source.visible && e.target.visible) [result addObject:e];
    }
    return result;
}

#pragma mark - Snapshot sync (main thread builds, sim queue adopts)

- (ESSimState *)buildSimState {
    ESSimState *s = [ESSimState new];
    NSUInteger n = _nodes.count;
    s->count = n;
    s->pos = calloc(MAX(n, 1), sizeof(CGPoint));
    s->vel = calloc(MAX(n, 1), sizeof(CGPoint));
    s->pinned = calloc(MAX(n, 1), sizeof(BOOL));
    s->visible = calloc(MAX(n, 1), sizeof(BOOL));

    NSMapTable<ESGraphNode *, NSNumber *> *index =
        [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsOpaqueMemory
                              valueOptions:NSPointerFunctionsStrongMemory];
    for (NSUInteger i = 0; i < n; i++) {
        ESGraphNode *node = _nodes[i];
        s->pos[i] = node.position;
        s->vel[i] = node.velocity;
        s->pinned[i] = node.pinned;
        s->visible[i] = node.visible;
        [index setObject:@(i) forKey:node];
    }

    // Edges whose endpoints are both in the node set; others are dropped.
    NSUInteger m = _edges.count;
    s->edgeA = calloc(MAX(m, 1), sizeof(NSUInteger));
    s->edgeB = calloc(MAX(m, 1), sizeof(NSUInteger));
    s->edgeExplicit = calloc(MAX(m, 1), sizeof(BOOL));
    NSUInteger k = 0;
    for (ESGraphEdge *e in _edges) {
        ESGraphNode *a = e.source, *b = e.target;
        NSNumber *ia = a ? [index objectForKey:a] : nil;
        NSNumber *ib = b ? [index objectForKey:b] : nil;
        if (!ia || !ib) continue;
        s->edgeA[k] = ia.unsignedIntegerValue;
        s->edgeB[k] = ib.unsignedIntegerValue;
        s->edgeExplicit[k] = e.isExplicitLink;
        k++;
    }
    s->edgeCount = k;
    s->generation = ++_generation;
    return s;
}

- (void)syncStructureIfNeeded {
    if (!_structureDirty) return;
    _structureDirty = NO;
    ESSimState *state = [self buildSimState];
    dispatch_async(_simQueue, ^{
        self->_sim = state;
        self->_simMaxDelta = CGFLOAT_MAX;
    });
}

#pragma mark - Simulation control (main thread)

- (BOOL)isRunning {
    return _running;
}

- (void)startSimulation {
    [self syncStructureIfNeeded];
    _running = YES;
    [self armStepTimer];
}

- (void)stopSimulation {
    _running = NO;
    dispatch_async(_simQueue, ^{
        [self cancelStepTimerOnSimQueue];
    });
}

- (void)armStepTimer {
    dispatch_async(_simQueue, ^{
        if (self->_stepTimer) return;    // already stepping
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_simQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), kStepIntervalNsec, kStepIntervalNsec / 4);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            [weakSelf stepOnSimQueue];
        });
        self->_stepTimer = timer;
        dispatch_resume(timer);
    });
}

- (void)cancelStepTimerOnSimQueue {
    if (!_stepTimer) return;
    dispatch_source_cancel(_stepTimer);
    _stepTimer = nil;
}

#pragma mark - Physics (simulation queue)

- (void)stepOnSimQueue {
    ESSimState *s = _sim;
    if (!s) return;

    // Physics update only when alpha is above minimum; once it has decayed
    // the timer goes idle until the next nudge or structure sync.
    if (_simAlpha < kAlphaMin) {
        [self cancelStepTimerOnSimQueue];
        return;
    }

    NSUInteger count = s->count;
    CGPoint *pos = s->pos;
    CGPoint *vel = s->vel;
    BOOL *pinned = s->pinned;
    BOOL *visible = s->visible;
    CGFloat alpha = _simAlpha;
    CGFloat maxDelta = 0;

    if (count > 0) {
        // 1. Repulsion (all visible pairs)
        for (NSUInteger i = 0; i < count; i++) {
            if (!visible[i] || pinned[i]) continue;
            for (NSUInteger j = i + 1; j < count; j++) {
                if (!visible[j]) continue;
                CGFloat dx = pos[i].x - pos[j].x;
                CGFloat dy = pos[i].y - pos[j].y;
                CGFloat dist = hypotf(dx, dy);
                if (dist < 1.0) dist = 1.0;
                if (dist > kRepulsionMaxDist) continue;

                CGFloat force = alpha * kRepulsionStrength / (dist * dist);
                CGFloat fx = force * dx / dist;
                CGFloat fy = force * dy / dist;

                vel[i].x += fx; vel[i].y += fy;
                if (!pinned[j]) { vel[j].x -= fx; vel[j].y -= fy; }
            }
        }

        // 2. Attraction (edges)
        for (NSUInteger e = 0; e < s->edgeCount; e++) {
            NSUInteger a = s->edgeA[e], b = s->edgeB[e];
            if (!visible[a] || !visible[b]) continue;

            CGFloat dx = pos[b].x - pos[a].x;
            CGFloat dy = pos[b].y - pos[a].y;
            CGFloat dist = hypotf(dx, dy);
            if (dist < 1.0) dist = 1.0;

            CGFloat rest = s->edgeExplicit[e] ? kLinkRestLength : kSimilarityRestLength;
            CGFloat displacement = dist - rest;
            CGFloat force = alpha * kSpringStrength * displacement;
            CGFloat fx = force * dx / dist;
            CGFloat fy = force * dy / dist;

            if (!pinned[a]) { vel[a].x += fx; vel[a].y += fy; }
            if (!pinned[b]) { vel[b].x -= fx; vel[b].y -= fy; }
        }

        // 3. Center gravity + damping + position update
        CGFloat cx = 0, cy = 0;
        NSUInteger visibleCount = 0;
        for (NSUInteger i = 0; i < count; i++) {
            if (!visible[i]) continue;
            cx += pos[i].x; cy += pos[i].y; visibleCount++;
        }
        if (visibleCount > 0) { cx /= visibleCount; cy /= visibleCount; }

        for (NSUInteger i = 0; i < count; i++) {
            if (!visible[i]) continue;
            if (pinned[i]) { vel[i] = CGPointZero; continue; }

            CGFloat gx = (cx - pos[i].x) * alpha * kCenterGravity;
            CGFloat gy = (cy - pos[i].y) * alpha * kCenterGravity;

            CGFloat vx = (vel[i].x + gx) * kDamping;
            CGFloat vy = (vel[i].y + gy) * kDamping;

            CGFloat speed = hypotf(vx, vy);
            if (speed > kMaxVelocity) {
                vx = vx / speed * kMaxVelocity;
                vy = vy / speed * kMaxVelocity;
            }

            vel[i] = CGPointMake(vx, vy);
            pos[i] = CGPointMake(pos[i].x + vx, pos[i].y + vy);

            CGFloat delta = hypotf(vx, vy);
            if (delta > maxDelta) maxDelta = delta;
        }
    }

    _simMaxDelta = maxDelta;
    _simAlpha = alpha * kAlphaDecay;

    // 4. Publish: copy positions/velocities and hand them to main.
    NSUInteger generation = s->generation;
    CGFloat publishedAlpha = _simAlpha;
    CGFloat publishedDelta = _simMaxDelta;
    NSData *posData = [NSData dataWithBytes:pos length:count * sizeof(CGPoint)];
    NSData *velData = [NSData dataWithBytes:vel length:count * sizeof(CGPoint)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyPublishedPositions:posData velocities:velData count:count
                           generation:generation alpha:publishedAlpha maxDelta:publishedDelta];
    });
}

#pragma mark - Publish (main thread)

- (void)applyPublishedPositions:(NSData *)posData velocities:(NSData *)velData count:(NSUInteger)count
                     generation:(NSUInteger)generation alpha:(CGFloat)alpha maxDelta:(CGFloat)maxDelta {
    // Stale publish from a structure that has since changed: drop it.
    if (generation != _generation || count != _nodes.count) return;

    const CGPoint *pos = posData.bytes;
    const CGPoint *vel = velData.bytes;
    for (NSUInteger i = 0; i < count; i++) {
        ESGraphNode *n = _nodes[i];
        if (n.pinned) continue;              // pinned nodes keep their main-thread position
        n.position = pos[i];
        n.velocity = vel[i];
    }
    _publishedAlpha = alpha;
    _publishedMaxDelta = maxDelta;
}

#pragma mark - Per-frame housekeeping (main thread)

- (void)decayFlash {
    for (ESGraphNode *n in _nodes) {
        if (n.flashIntensity > 0.01) {
            n.flashIntensity *= kFlashDecay;
        } else {
            n.flashIntensity = 0.0;
        }
    }
}

- (BOOL)isSettled {
    if (_publishedAlpha >= kAlphaMin || _publishedMaxDelta >= kSettleDelta) return NO;
    for (ESGraphNode *n in _nodes) {
        if (n.flashIntensity > 0.01) return NO;
    }
    return YES;
}

#pragma mark - Hit Testing

- (ESGraphNode *)nodeAtPoint:(CGPoint)point radius:(CGFloat)r {
    CGFloat bestDist = r;
    ESGraphNode *best = nil;
    for (ESGraphNode *n in _nodes) {
        if (!n.visible) continue;
        CGFloat dx = n.position.x - point.x;
        CGFloat dy = n.position.y - point.y;
        CGFloat dist = hypotf(dx, dy);
        if (dist < bestDist) {
            bestDist = dist;
            best = n;
        }
    }
    return best;
}

#pragma mark - Bounding Rect

- (CGRect)boundingRect {
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    BOOL any = NO;
    for (ESGraphNode *n in _nodes) {
        if (!n.visible) continue;
        any = YES;
        if (n.position.x < minX) minX = n.position.x;
        if (n.position.y < minY) minY = n.position.y;
        if (n.position.x > maxX) maxX = n.position.x;
        if (n.position.y > maxY) maxY = n.position.y;
    }
    if (!any) return CGRectZero;
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

@end
