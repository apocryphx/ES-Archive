//
//  ESMemoryScopeView.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryScopeView.h"
#import "ESForceGraph.h"
#import "ESColorLUT.h"
#import "ESMemoryNotifications.h"
#import "ESMemoryScopeDataSource.h"

static const CGFloat kNodeRadius      = 6.0;
static const CGFloat kEdgeStrokeWidth = 2.0;  // CDLink edges (Phase 1 only)
static const NSTimeInterval kFrameInterval = 1.0 / 60.0;
static const CGFloat kZoomMin         = 0.1;
static const CGFloat kZoomMax         = 50.0;
static const CGFloat kScrollZoomSpeed = 0.05;  // per discrete scroll tick
static const NSTimeInterval kCenteringDuration = 0.7;

@interface ESMemoryScopeView ()
@property (nonatomic, strong) NSTimer *animationTimer;

// Drawing cache — rebuilt each tick
@property (nonatomic, strong) NSMutableArray<NSBezierPath *> *cachedEdgePaths;
@property (nonatomic, strong) NSMutableArray<NSColor *>      *cachedEdgeColors;
@property (nonatomic, strong) NSMutableArray<NSBezierPath *> *cachedNodePaths;
@property (nonatomic, strong) NSMutableArray<NSColor *>      *cachedNodeColors;

// Transform state
@property (nonatomic) CGFloat  viewScale;
@property (nonatomic) CGPoint  viewOffset;
@property (nonatomic) BOOL     hasUserTransform;

// Resize tracking
@property (nonatomic) NSSize   previousBoundsSize;

// Gesture recognizers
@property (nonatomic, strong) NSPanGestureRecognizer            *panRecognizer;
@property (nonatomic, strong) NSMagnificationGestureRecognizer  *magnifyRecognizer;
@property (nonatomic, strong) NSClickGestureRecognizer          *singleClickRecognizer;
@property (nonatomic, strong) NSClickGestureRecognizer          *doubleClickRecognizer;
@property (nonatomic) NSPoint  panLastLocation;

// Centering animation
@property (nonatomic) BOOL     centeringResetsTransform;
@property (nonatomic, strong) NSTimer *centeringTimer;
@property (nonatomic) CGPoint  centeringStartOffset;
@property (nonatomic) CGPoint  centeringTargetOffset;
@property (nonatomic) CGFloat  centeringStartScale;
@property (nonatomic) CGFloat  centeringTargetScale;
@property (nonatomic) CFAbsoluteTime centeringStartTime;

// Selection highlight
@property (nonatomic, strong) NSBezierPath *selectionRingPath;

// Hover popover
@property (nonatomic, weak) ESGraphNode *hoveredNode;
@property (nonatomic, strong) NSPopover *nodePopover;

// Flash animation
@property (nonatomic, strong) NSMutableArray *notificationObservers;
@property (nonatomic, strong) NSArray<ESGraphNode *> *cachedVisibleNodes;
@end

@implementation ESMemoryScopeView

// Stable per-persona color for All (witness) mode. A fixed qualitative palette
// indexed by a deterministic hash of the author name, so a persona keeps the
// same hue across launches and however many personas exist.
+ (NSColor *)colorForAuthor:(nullable NSString *)author {
    static NSArray<NSColor *> *palette = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palette = @[
            [NSColor systemBlueColor],   [NSColor systemPinkColor],
            [NSColor systemGreenColor],  [NSColor systemOrangeColor],
            [NSColor systemPurpleColor], [NSColor systemTealColor],
            [NSColor systemYellowColor], [NSColor systemRedColor],
        ];
    });
    if (author.length == 0) return [NSColor systemGrayColor];
    NSUInteger h = 5381;
    for (NSUInteger i = 0; i < author.length; i++) {
        h = ((h << 5) + h) + [author characterAtIndex:i];  // djb2
    }
    return palette[h % palette.count];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _cachedEdgePaths  = [NSMutableArray array];
    _cachedEdgeColors = [NSMutableArray array];
    _cachedNodePaths  = [NSMutableArray array];
    _cachedNodeColors = [NSMutableArray array];

    _viewScale = 1.0;
    _viewOffset = CGPointZero;
    _hasUserTransform = NO;
    _previousBoundsSize = NSZeroSize;

    // Gesture recognizers
    _panRecognizer = [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:_panRecognizer];

    _magnifyRecognizer = [[NSMagnificationGestureRecognizer alloc] initWithTarget:self action:@selector(handleMagnify:)];
    [self addGestureRecognizer:_magnifyRecognizer];

    _singleClickRecognizer = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleClick:)];
    _singleClickRecognizer.numberOfClicksRequired = 1;
    [self addGestureRecognizer:_singleClickRecognizer];

    _doubleClickRecognizer = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleClick:)];
    _doubleClickRecognizer.numberOfClicksRequired = 2;
    [self addGestureRecognizer:_doubleClickRecognizer];

    // No failure requirement — single-click fires immediately.
    // Double-click fires two single-clicks first, which is harmless
    // because single-click uses non-toggle select logic.

    // Memory access notification observer
    _notificationObservers = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    id token = [[NSNotificationCenter defaultCenter]
        addObserverForName:ESMemoryAccessNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    [weakSelf handleAccessNotification:note];
                }];
    [_notificationObservers addObject:token];
}

- (void)dealloc {
    for (id token in _notificationObservers) {
        [[NSNotificationCenter defaultCenter] removeObserver:token];
    }
    [_animationTimer invalidate];
    [_centeringTimer invalidate];
    [_nodePopover close];
}

- (BOOL)isFlipped {
    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    // Remove old tracking areas
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

#pragma mark - Simulation Control

- (void)startSimulation {
    if (self.animationTimer) return;
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:kFrameInterval
                                                          target:self
                                                        selector:@selector(simulationStep)
                                                        userInfo:nil
                                                         repeats:YES];
    // Keep timer alive during event tracking (e.g., window resize)
    [[NSRunLoop currentRunLoop] addTimer:self.animationTimer
                                 forMode:NSRunLoopCommonModes];
}

- (void)stopSimulation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

- (void)simulationStep {
    if (!self.graph) return;

    [self.graph tick];
    [self rebuildDrawingCache];
    [self setNeedsDisplay:YES];

    // Stop timer once settled
    if (self.graph.isSettled) {
        [self stopSimulation];
    }
}

#pragma mark - Drawing Cache

- (void)computeAutoFitScale:(CGFloat *)outScale offset:(CGPoint *)outOffset {
    CGRect bounds = self.bounds;
    CGRect graphRect = self.graph.boundingRect;

    CGFloat s = 1.0;
    CGFloat ox = 0, oy = 0;

    if (!CGRectIsEmpty(graphRect) && graphRect.size.width > 0 && graphRect.size.height > 0) {
        CGFloat pad = 40.0;
        CGFloat availW = bounds.size.width  - pad * 2;
        CGFloat availH = bounds.size.height - pad * 2;
        CGFloat scaleX = availW / graphRect.size.width;
        CGFloat scaleY = availH / graphRect.size.height;
        s = fmin(scaleX, scaleY);
        if (s > 3.0) s = 3.0;  // don't over-zoom when few nodes

        CGFloat graphCenterX = graphRect.origin.x + graphRect.size.width  * 0.5;
        CGFloat graphCenterY = graphRect.origin.y + graphRect.size.height * 0.5;
        ox = bounds.size.width  * 0.5 - graphCenterX * s;
        oy = bounds.size.height * 0.5 - graphCenterY * s;
    } else {
        // Single node or empty — center in view
        ox = bounds.size.width  * 0.5;
        oy = bounds.size.height * 0.5;
    }

    *outScale  = s;
    *outOffset = CGPointMake(ox, oy);
}

- (void)rebuildDrawingCache {
    [self.cachedEdgePaths removeAllObjects];
    [self.cachedEdgeColors removeAllObjects];
    [self.cachedNodePaths removeAllObjects];
    [self.cachedNodeColors removeAllObjects];

    if (!self.graph) return;

    // Resolve transform: auto-fit or user-controlled
    CGFloat scale, offsetX, offsetY;

    if (!self.hasUserTransform) {
        CGPoint offset;
        [self computeAutoFitScale:&scale offset:&offset];
        self.viewScale  = scale;
        self.viewOffset = offset;
        offsetX = offset.x;
        offsetY = offset.y;
    } else {
        scale   = self.viewScale;
        offsetX = self.viewOffset.x;
        offsetY = self.viewOffset.y;
    }

    // Cache edges — CDLink bold, similarity normalized
    NSColor *linkColor = [NSColor.separatorColor colorWithAlphaComponent:0.8];
    NSArray<ESGraphEdge *> *visibleEdges = self.graph.visibleEdges;

    // Find max similarity weight for normalization
    CGFloat maxSimWeight = 0.0;
    for (ESGraphEdge *edge in visibleEdges) {
        if (!edge.isExplicitLink && edge.weight > maxSimWeight) {
            maxSimWeight = edge.weight;
        }
    }
    if (maxSimWeight <= 0.0) maxSimWeight = 1.0;

    for (ESGraphEdge *edge in visibleEdges) {
        CGFloat x1 = edge.source.position.x * scale + offsetX;
        CGFloat y1 = edge.source.position.y * scale + offsetY;
        CGFloat x2 = edge.target.position.x * scale + offsetX;
        CGFloat y2 = edge.target.position.y * scale + offsetY;

        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NSMakePoint(x1, y1)];
        [path lineToPoint:NSMakePoint(x2, y2)];

        NSColor *color;
        if (edge.isExplicitLink) {
            path.lineWidth = kEdgeStrokeWidth;
            color = linkColor;
        } else {
            // make soft edgedes distinct from hard edges using alpha
            const CGFloat _maxAlpha = 0.7;
            path.lineWidth = 0.5;
            // Normalize to [0,1] then sqrt to spread the low end
            CGFloat normalized = edge.weight / maxSimWeight;
            CGFloat alpha = sqrt(normalized)*_maxAlpha;
            color = [NSColor.separatorColor colorWithAlphaComponent:alpha];
        }

        [self.cachedEdgePaths addObject:path];
        [self.cachedEdgeColors addObject:color];
    }

    // Cache nodes
    NSArray<ESGraphNode *> *visibleNodes = self.graph.visibleNodes;
    self.cachedVisibleNodes = visibleNodes;
    ESColorLUT *lut = self.colorLUT;
    NSColor *fallbackFill = NSColor.controlAccentColor;
    CGFloat r = kNodeRadius * scale;
    if (r < 3.0) r = 3.0;
    if (r > 12.0) r = 12.0;

    for (ESGraphNode *node in visibleNodes) {
        CGFloat x = node.position.x * scale + offsetX;
        CGFloat y = node.position.y * scale + offsetY;

        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(x - r, y - r, r * 2, r * 2)];

        [self.cachedNodePaths addObject:path];

        NSColor *color;
        if (self.colorByPersona) {
            color = [ESMemoryScopeView colorForAuthor:node.author];
        } else {
            color = lut ? [lut colorForValue:node.heat] : fallbackFill;
        }
        [self.cachedNodeColors addObject:color];
    }

    // Selection highlight ring
    self.selectionRingPath = nil;
    if (self.selectedNode && self.selectedNode.visible) {
        CGFloat sx = self.selectedNode.position.x * scale + offsetX;
        CGFloat sy = self.selectedNode.position.y * scale + offsetY;
        CGFloat ringR = r + 4.0;
        self.selectionRingPath = [NSBezierPath bezierPathWithOvalInRect:
            NSMakeRect(sx - ringR, sy - ringR, ringR * 2, ringR * 2)];
        self.selectionRingPath.lineWidth = 2.0;
    }
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    // Background — adapts to light/dark mode (fill bounds, NOT dirtyRect,
    // to avoid painting over sibling views when the dirty region extends beyond our frame)
    [NSColor.windowBackgroundColor set];
    NSRectFill(self.bounds);

    // Edges
    NSUInteger edgeCount = self.cachedEdgePaths.count;
    for (NSUInteger i = 0; i < edgeCount; i++) {
        [self.cachedEdgeColors[i] set];
        [self.cachedEdgePaths[i] stroke];
    }

    // Nodes — fill then stroke ring
    NSUInteger nodeCount = self.cachedNodePaths.count;
    NSArray<ESGraphNode *> *visibleNodes = self.cachedVisibleNodes;
    for (NSUInteger i = 0; i < nodeCount; i++) {
        NSColor *fillColor = self.cachedNodeColors[i];
        if (i < visibleNodes.count) {
            ESGraphNode *node = visibleNodes[i];
            if (node.flashIntensity > 0.01) {
                fillColor = [fillColor blendedColorWithFraction:node.flashIntensity
                                                        ofColor:NSColor.whiteColor];
            }
        }
        [fillColor set];
        [self.cachedNodePaths[i] fill];
    }

    // Selection highlight ring
    if (self.selectionRingPath) {
        [NSColor.controlAccentColor set];
        [self.selectionRingPath stroke];
    }

    // Empty state
    if (nodeCount == 0) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightLight],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
            NSParagraphStyleAttributeName: style,
        };
        NSString *msg = @"No memories yet";
        NSSize sz = [msg sizeWithAttributes:attrs];
        CGRect bounds = self.bounds;
        [msg drawAtPoint:NSMakePoint((bounds.size.width - sz.width) * 0.5,
                                     (bounds.size.height - sz.height) * 0.5)
          withAttributes:attrs];
    }
}

#pragma mark - User Interaction

- (void)cancelCentering {
    [self.centeringTimer invalidate];
    self.centeringTimer = nil;
    self.centeringResetsTransform = NO;
    [self dismissNodePopover];
    self.hoveredNode = nil;
}

- (void)scrollWheel:(NSEvent *)event {
    // Suppress scroll during active pinch to prevent double-fire jitter
    NSGestureRecognizerState ms = self.magnifyRecognizer.state;
    if (ms == NSGestureRecognizerStateBegan ||
        ms == NSGestureRecognizerStateChanged) return;

    [self cancelCentering];  // also dismisses popover

    CGFloat delta = event.scrollingDeltaY;
    if (fabs(delta) < 0.01) return;

    // Cursor position in view coordinates
    NSPoint cursor = [self convertPoint:event.locationInWindow fromView:nil];

    // Graph-space point under cursor (before zoom)
    CGFloat gx = (cursor.x - self.viewOffset.x) / self.viewScale;
    CGFloat gy = (cursor.y - self.viewOffset.y) / self.viewScale;

    // Compute zoom factor — trackpad delivers smooth fractional deltas
    CGFloat zoomFactor;
    if (event.hasPreciseScrollingDeltas) {
        zoomFactor = 1.0 + delta * 0.01;
    } else {
        zoomFactor = 1.0 + delta * kScrollZoomSpeed;
    }

    CGFloat newScale = self.viewScale * zoomFactor;
    newScale = fmax(kZoomMin, fmin(kZoomMax, newScale));

    // Adjust offset so the graph point under cursor stays fixed
    CGPoint newOffset;
    newOffset.x = cursor.x - gx * newScale;
    newOffset.y = cursor.y - gy * newScale;

    self.viewScale  = newScale;
    self.viewOffset = newOffset;
    self.hasUserTransform = YES;

    [self rebuildDrawingCache];
    [self setNeedsDisplay:YES];
}

- (void)handlePan:(NSPanGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        [self cancelCentering];
        self.panLastLocation = [recognizer locationInView:self];
    } else if (recognizer.state == NSGestureRecognizerStateChanged) {
        NSPoint loc = [recognizer locationInView:self];
        CGFloat dx = loc.x - self.panLastLocation.x;
        CGFloat dy = loc.y - self.panLastLocation.y;

        self.viewOffset = CGPointMake(self.viewOffset.x + dx, self.viewOffset.y + dy);
        self.panLastLocation = loc;
        self.hasUserTransform = YES;

        [self rebuildDrawingCache];
        [self setNeedsDisplay:YES];
    }
}

- (void)handleMagnify:(NSMagnificationGestureRecognizer *)recognizer {
    if (recognizer.state == NSGestureRecognizerStateBegan) {
        [self cancelCentering];
    }

    NSPoint cursor = [recognizer locationInView:self];
    CGFloat gx = (cursor.x - self.viewOffset.x) / self.viewScale;
    CGFloat gy = (cursor.y - self.viewOffset.y) / self.viewScale;

    CGFloat newScale = self.viewScale * (1.0 + recognizer.magnification);
    newScale = fmax(kZoomMin, fmin(kZoomMax, newScale));

    CGPoint newOffset;
    newOffset.x = cursor.x - gx * newScale;
    newOffset.y = cursor.y - gy * newScale;

    self.viewScale  = newScale;
    self.viewOffset = newOffset;
    self.hasUserTransform = YES;

    // Reset to zero so each .Changed delivers an incremental delta
    recognizer.magnification = 0.0;

    [self rebuildDrawingCache];
    [self setNeedsDisplay:YES];
}

- (void)handleSingleClick:(NSClickGestureRecognizer *)recognizer {
    NSPoint loc = [recognizer locationInView:self];
    CGFloat gx = (loc.x - self.viewOffset.x) / self.viewScale;
    CGFloat gy = (loc.y - self.viewOffset.y) / self.viewScale;
    CGFloat hitRadius = 12.0 / self.viewScale;

    ESGraphNode *hitNode = [self.graph nodeAtPoint:CGPointMake(gx, gy) radius:hitRadius];

    // Non-toggle: click node = select, click empty = deselect.
    // Double-click harmlessly fires two of these before its handler runs.
    if (hitNode != self.selectedNode) {
        self.selectedNode = hitNode;  // nil when clicking empty space
        [self rebuildDrawingCache];
        [self setNeedsDisplay:YES];
        if ([self.delegate respondsToSelector:@selector(memoryScopeView:didSelectNode:)]) {
            [self.delegate memoryScopeView:self didSelectNode:hitNode];
        }
    }
}

- (void)handleDoubleClick:(NSClickGestureRecognizer *)recognizer {
    [self cancelCentering];

    NSPoint loc = [recognizer locationInView:self];
    CGFloat gx = (loc.x - self.viewOffset.x) / self.viewScale;
    CGFloat gy = (loc.y - self.viewOffset.y) / self.viewScale;
    CGFloat hitRadius = 12.0 / self.viewScale;

    ESGraphNode *hitNode = [self.graph nodeAtPoint:CGPointMake(gx, gy) radius:hitRadius];
    if (hitNode) {
        [self animateCenterOnGraphPoint:hitNode.position];
    } else {
        [self resetToFit];
    }
}

#pragma mark - Hover Popover

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat gx = (loc.x - self.viewOffset.x) / self.viewScale;
    CGFloat gy = (loc.y - self.viewOffset.y) / self.viewScale;
    CGFloat hitRadius = 12.0 / self.viewScale;

    ESGraphNode *hit = [self.graph nodeAtPoint:CGPointMake(gx, gy) radius:hitRadius];

    if (hit == self.hoveredNode) return;

    self.hoveredNode = hit;
    [self dismissNodePopover];

    if (hit) {
        [self showNodePopoverForNode:hit];
    }
}

- (void)showNodePopoverForNode:(ESGraphNode *)node {
    // Build content view controller with a label
    NSViewController *vc = [[NSViewController alloc] init];
    NSTextField *label = [NSTextField labelWithString:[self.dataSource titleForNode:node]];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;

    NSGlassEffectView *container = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:4],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
    ]];
    vc.view = container;

    // Create and show popover
    self.nodePopover = [[NSPopover alloc] init];
    self.nodePopover.contentViewController = vc;
    // Application-defined, not semitransient: we drive dismissal ourselves
    // (hover change, scroll, pan, double-click). Semitransient would auto-close
    // the popover the moment the node is clicked, making the label vanish.
    self.nodePopover.behavior = NSPopoverBehaviorApplicationDefined;
    self.nodePopover.animates = NO;

    // Position at node's view-space location
    CGFloat vx = node.position.x * self.viewScale + self.viewOffset.x;
    CGFloat vy = node.position.y * self.viewScale + self.viewOffset.y;
    NSRect posRect = NSMakeRect(vx - 4, vy - 4, 8, 8);

    [self.nodePopover showRelativeToRect:posRect
                                  ofView:self
                           preferredEdge:NSRectEdgeMinY];

    // The popover is purely informational and must never intercept input.
    // Letting its window ignore mouse events allows scroll-zoom and the pinch
    // magnify gesture to fall through to the scope view beneath, so zooming
    // keeps working even when the cursor rests on a node or its label.
    self.nodePopover.contentViewController.view.window.ignoresMouseEvents = YES;
}

- (void)dismissNodePopover {
    [self.nodePopover close];
    self.nodePopover = nil;
}

- (void)resetToFit {
    // Always animate smoothly to the auto-fit transform
    self.centeringResetsTransform = YES;
    CGFloat fitScale;
    CGPoint fitOffset;
    [self computeAutoFitScale:&fitScale offset:&fitOffset];
    [self animateToScale:fitScale offset:fitOffset];
}

- (void)animateCenterOnGraphPoint:(CGPoint)graphPoint {
    self.centeringResetsTransform = NO;
    CGRect bounds = self.bounds;
    CGFloat targetX = bounds.size.width  * 0.5 - graphPoint.x * self.viewScale;
    CGFloat targetY = bounds.size.height * 0.5 - graphPoint.y * self.viewScale;

    // Keep current zoom, just slide the offset
    [self animateToScale:self.viewScale offset:CGPointMake(targetX, targetY)];
}

- (void)animateToScale:(CGFloat)targetScale offset:(CGPoint)targetOffset {
    self.centeringStartOffset  = self.viewOffset;
    self.centeringTargetOffset = targetOffset;
    self.centeringStartScale   = self.viewScale;
    self.centeringTargetScale  = targetScale;
    self.centeringStartTime    = CFAbsoluteTimeGetCurrent();
    self.hasUserTransform = YES;

    [self.centeringTimer invalidate];
    self.centeringTimer = [NSTimer scheduledTimerWithTimeInterval:kFrameInterval
                                                          target:self
                                                        selector:@selector(centeringStep)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)centeringStep {
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - self.centeringStartTime;
    CGFloat t = elapsed / kCenteringDuration;

    BOOL finished = (t >= 1.0);
    if (finished) {
        t = 1.0;
        [self.centeringTimer invalidate];
        self.centeringTimer = nil;
    }

    // Ease-out cubic: fast start, gentle landing
    CGFloat eased = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t);

    self.viewScale = self.centeringStartScale
                   + (self.centeringTargetScale - self.centeringStartScale) * eased;
    CGFloat ox = self.centeringStartOffset.x
               + (self.centeringTargetOffset.x - self.centeringStartOffset.x) * eased;
    CGFloat oy = self.centeringStartOffset.y
               + (self.centeringTargetOffset.y - self.centeringStartOffset.y) * eased;
    self.viewOffset = CGPointMake(ox, oy);

    // Once finished, drop back to auto-fit mode only if resetToFit initiated this
    if (finished && self.centeringResetsTransform) {
        self.hasUserTransform = NO;
        self.centeringResetsTransform = NO;
    }

    [self rebuildDrawingCache];
    [self setNeedsDisplay:YES];
}

#pragma mark - Resize

- (void)setFrameSize:(NSSize)newSize {
    NSSize oldSize = self.previousBoundsSize;
    [super setFrameSize:newSize];

    // First layout — just record size
    if (oldSize.width < 1.0 || oldSize.height < 1.0) {
        self.previousBoundsSize = newSize;
        return;
    }

    if (self.hasUserTransform) {
        // Shift offset to keep graph centered in the resized view
        CGFloat dx = (newSize.width  - oldSize.width)  * 0.5;
        CGFloat dy = (newSize.height - oldSize.height) * 0.5;
        self.viewOffset = CGPointMake(self.viewOffset.x + dx, self.viewOffset.y + dy);
    }

    self.previousBoundsSize = newSize;

    // If simulation is idle, manually trigger redraw
    if (!self.animationTimer) {
        [self rebuildDrawingCache];
        [self setNeedsDisplay:YES];
    }
}

#pragma mark - View Lifecycle

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [self stopSimulation];
    }
}

#pragma mark - Memory Access Animation

- (void)handleAccessNotification:(NSNotification *)note {
    ESMemoryAccessType type = [note.userInfo[ESMemoryAccessTypeKey] unsignedIntegerValue];

    switch (type) {
        case ESMemoryAccessTypeRead:
            [self animateRead:note.userInfo];     break;
        case ESMemoryAccessTypeSearch:
            [self animateSearch:note.userInfo];   break;
        case ESMemoryAccessTypeDiscover:
            [self animateDiscover:note.userInfo]; break;
        case ESMemoryAccessTypeRecent:
            [self animateRecent:note.userInfo];   break;
        case ESMemoryAccessTypeTagged:
            [self animateTagged:note.userInfo];   break;
        case ESMemoryAccessTypeLinks:
            [self animateLinks:note.userInfo];    break;
    }
}

- (void)flashNode:(ESGraphNode *)node
        intensity:(CGFloat)intensity
            delay:(NSTimeInterval)delay {
    if (!node) return;
    if (delay < 0.001) {
        node.flashIntensity = fmax(node.flashIntensity, intensity);
        [self startSimulation];
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            node.flashIntensity = fmax(node.flashIntensity, intensity);
            [self startSimulation];
        });
    }
}

- (void)animateRead:(NSDictionary *)userInfo {
    NSArray *ids = userInfo[ESMemoryAccessObjectIDsKey];
    if (ids.count == 0) return;
    [self flashNode:self.dataSource.nodeMap[ids[0]] intensity:1.0 delay:0.0];
}

- (void)animateSearch:(NSDictionary *)userInfo {
    NSArray *ids    = userInfo[ESMemoryAccessObjectIDsKey];
    NSArray *scores = userInfo[ESMemoryAccessScoresKey];
    for (NSUInteger i = 0; i < ids.count; i++) {
        ESGraphNode *node = self.dataSource.nodeMap[ids[i]];
        CGFloat intensity = (i < scores.count) ? [scores[i] floatValue] : 0.5;
        [self flashNode:node intensity:intensity delay:i * 0.08];
    }
}

- (void)animateDiscover:(NSDictionary *)userInfo {
    NSArray *ids    = userInfo[ESMemoryAccessObjectIDsKey];
    NSArray *scores = userInfo[ESMemoryAccessScoresKey];
    for (NSUInteger i = 0; i < ids.count; i++) {
        ESGraphNode *node = self.dataSource.nodeMap[ids[i]];
        CGFloat intensity = (i < scores.count) ? [scores[i] floatValue] : 0.5;
        [self flashNode:node intensity:intensity delay:i * 0.18];
    }
}

- (void)animateRecent:(NSDictionary *)userInfo {
    NSArray *ids = userInfo[ESMemoryAccessObjectIDsKey];
    for (NSUInteger i = 0; i < ids.count; i++) {
        ESGraphNode *node = self.dataSource.nodeMap[ids[i]];
        [self flashNode:node intensity:0.75 delay:i * 0.12];
    }
}

- (void)animateTagged:(NSDictionary *)userInfo {
    for (NSManagedObjectID *oid in userInfo[ESMemoryAccessObjectIDsKey]) {
        [self flashNode:self.dataSource.nodeMap[oid] intensity:0.8 delay:0.0];
    }
}

- (void)animateLinks:(NSDictionary *)userInfo {
    NSManagedObjectID *originID = userInfo[ESMemoryAccessOriginIDKey];
    NSArray *neighborIDs        = userInfo[ESMemoryAccessObjectIDsKey];

    [self flashNode:self.dataSource.nodeMap[originID] intensity:1.0 delay:0.0];

    for (NSUInteger i = 0; i < neighborIDs.count; i++) {
        ESGraphNode *neighbor = self.dataSource.nodeMap[neighborIDs[i]];
        [self flashNode:neighbor intensity:0.65 delay:0.1 + i * 0.07];
    }
}

@end
