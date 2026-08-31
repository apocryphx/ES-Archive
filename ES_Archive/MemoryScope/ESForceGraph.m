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

#pragma mark - ESGraphNode

@implementation ESGraphNode
@end

#pragma mark - ESGraphEdge

@implementation ESGraphEdge
@end

#pragma mark - ESForceGraph

@implementation ESForceGraph {
    NSMutableArray<ESGraphNode *> *_nodes;
    NSMutableArray<ESGraphEdge *> *_edges;
    CGFloat _maxDelta;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodes = [NSMutableArray array];
        _edges = [NSMutableArray array];
        _alpha = 1.0;
        _maxDelta = CGFLOAT_MAX;  // force at least one tick before settling
    }
    return self;
}

- (NSArray<ESGraphNode *> *)nodes { return _nodes; }
- (NSArray<ESGraphEdge *> *)edges { return _edges; }

- (void)addNode:(ESGraphNode *)node {
    [_nodes addObject:node];
}

- (void)removeNode:(ESGraphNode *)node {
    [_nodes removeObject:node];
}

- (void)addEdge:(ESGraphEdge *)edge {
    [_edges addObject:edge];
}

- (void)removeEdge:(ESGraphEdge *)edge {
    [_edges removeObject:edge];
}

- (void)removeAllNodesAndEdges {
    [_nodes removeAllObjects];
    [_edges removeAllObjects];
    _alpha = 1.0;
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

#pragma mark - Force Simulation

- (void)tick {
    // Physics update only when alpha is above minimum
    if (_alpha >= kAlphaMin) {
        NSArray<ESGraphNode *> *visible = self.visibleNodes;
        NSUInteger count = visible.count;

        if (count > 0) {
            // 1. Repulsion (all visible pairs)
            for (NSUInteger i = 0; i < count; i++) {
                ESGraphNode *a = visible[i];
                if (a.pinned) continue;
                for (NSUInteger j = i + 1; j < count; j++) {
                    ESGraphNode *b = visible[j];
                    CGFloat dx = a.position.x - b.position.x;
                    CGFloat dy = a.position.y - b.position.y;
                    CGFloat dist = hypotf(dx, dy);
                    if (dist < 1.0) dist = 1.0;
                    if (dist > kRepulsionMaxDist) continue;

                    CGFloat force = _alpha * kRepulsionStrength / (dist * dist);
                    CGFloat fx = force * dx / dist;
                    CGFloat fy = force * dy / dist;

                    a.velocity = CGPointMake(a.velocity.x + fx, a.velocity.y + fy);
                    if (!b.pinned) {
                        b.velocity = CGPointMake(b.velocity.x - fx, b.velocity.y - fy);
                    }
                }
            }

            // 2. Attraction (edges)
            for (ESGraphEdge *edge in _edges) {
                ESGraphNode *s = edge.source;
                ESGraphNode *t = edge.target;
                if (!s.visible || !t.visible) continue;

                CGFloat dx = t.position.x - s.position.x;
                CGFloat dy = t.position.y - s.position.y;
                CGFloat dist = hypotf(dx, dy);
                if (dist < 1.0) dist = 1.0;

                CGFloat rest = edge.isExplicitLink ? kLinkRestLength : kSimilarityRestLength;
                CGFloat displacement = dist - rest;
                CGFloat force = _alpha * kSpringStrength * displacement;
                CGFloat fx = force * dx / dist;
                CGFloat fy = force * dy / dist;

                if (!s.pinned) {
                    s.velocity = CGPointMake(s.velocity.x + fx, s.velocity.y + fy);
                }
                if (!t.pinned) {
                    t.velocity = CGPointMake(t.velocity.x - fx, t.velocity.y - fy);
                }
            }

            // 3. Center gravity + damping + position update
            CGFloat cx = 0, cy = 0;
            for (ESGraphNode *n in visible) {
                cx += n.position.x;
                cy += n.position.y;
            }
            cx /= count;
            cy /= count;

            CGFloat maxDelta = 0;

            for (ESGraphNode *n in visible) {
                if (n.pinned) {
                    n.velocity = CGPointZero;
                    continue;
                }

                CGFloat gx = (cx - n.position.x) * _alpha * kCenterGravity;
                CGFloat gy = (cy - n.position.y) * _alpha * kCenterGravity;

                CGFloat vx = (n.velocity.x + gx) * kDamping;
                CGFloat vy = (n.velocity.y + gy) * kDamping;

                CGFloat speed = hypotf(vx, vy);
                if (speed > kMaxVelocity) {
                    vx = vx / speed * kMaxVelocity;
                    vy = vy / speed * kMaxVelocity;
                }

                n.velocity = CGPointMake(vx, vy);
                n.position = CGPointMake(n.position.x + vx, n.position.y + vy);

                CGFloat delta = hypotf(vx, vy);
                if (delta > maxDelta) maxDelta = delta;
            }

            _maxDelta = maxDelta;
        }

        // 4. Alpha decay
        _alpha *= kAlphaDecay;
    }

    // 5. Flash decay — runs even when physics is done
    for (ESGraphNode *n in _nodes) {
        if (n.flashIntensity > 0.01) {
            n.flashIntensity *= kFlashDecay;
        } else {
            n.flashIntensity = 0.0;
        }
    }
}

- (BOOL)isSettled {
    if (_alpha >= kAlphaMin || _maxDelta >= kSettleDelta) return NO;
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
