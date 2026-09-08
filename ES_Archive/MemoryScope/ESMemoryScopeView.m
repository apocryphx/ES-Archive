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
#import "ESScopeRenderer.h"
#import "ESLog.h"
#import <QuartzCore/QuartzCore.h>

// Drawing model: the view is an update-layer view (wantsUpdateLayer). Each frame
// main snapshots node positions/flash into flat buffers; ESScopeRenderer
// rasterizes them off main; the completion stores the CGImage and asks for a
// display pass, and -updateLayer assigns it to self.layer.contents. Colors and
// edge index pairs are rebuilt only when the structure or the appearance
// changes. Hit testing, gestures, hover and selection read node.position on
// main exactly as before.
static const CGFloat kNodeRadius      = 6.0;
static const NSTimeInterval kFrameInterval = 1.0 / 60.0;
static const CGFloat kZoomMin         = 0.1;
static const CGFloat kZoomMax         = 50.0;
static const CGFloat kScrollZoomSpeed = 0.05;  // per discrete scroll tick
static const NSTimeInterval kCenteringDuration = 0.7;

@interface ESMemoryScopeView ()
@property (nonatomic, strong) NSTimer *animationTimer;

// Rendering
@property (nonatomic, strong) ESScopeRenderer *renderer;
@property (nonatomic) CGImageRef latestImage;                   // +1, assigned in -updateLayer
@property (nonatomic) BOOL frameStructureDirty;                 // nodes/edges/colors need rebuilding
@property (nonatomic, strong) NSArray<ESGraphNode *> *frameNodes;
@property (nonatomic, strong) NSMapTable<ESGraphNode *, NSNumber *> *frameNodeIndex;
@property (nonatomic, strong) NSData *frameNodeColors;          // ESScopeColor[n]
@property (nonatomic, strong) NSData *frameEdgeIndices;         // uint32[2e]
@property (nonatomic, strong) NSData *frameEdgeAlpha;           // float[e]
@property (nonatomic, strong) NSData *frameEdgeIsLink;          // uint8[e]
@property (nonatomic) NSUInteger frameEdgeCount;
@property (nonatomic) NSUInteger lastNodeCount;
// Instrumentation, aggregated and logged about once a second under [Scope]
@property (nonatomic) double statAssembleMs, statRasterMs, statLatencyMs, statMaxLatencyMs;
@property (nonatomic) NSUInteger statSubmitted, statCompleted, statDropped;
@property (nonatomic, strong) ESScopeRenderStats *statLast;
@property (nonatomic) CFAbsoluteTime statWindowStart;

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

// Hover popover
@property (nonatomic, weak) ESGraphNode *hoveredNode;
@property (nonatomic, strong) NSPopover *nodePopover;

// Flash animation
@property (nonatomic, strong) NSMutableArray *notificationObservers;
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
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    _renderer = [[ESScopeRenderer alloc] init];
    _frameStructureDirty = YES;
    _frameNodeIndex = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory
                                             valueOptions:NSPointerFunctionsStrongMemory];

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
    if (_latestImage) CGImageRelease(_latestImage);
}

#pragma mark - Properties that change the frame structure

- (void)setGraph:(ESForceGraph *)graph {
    _graph = graph;
    self.frameStructureDirty = YES;
}

- (void)setColorLUT:(ESColorLUT *)colorLUT {
    _colorLUT = colorLUT;
    self.frameStructureDirty = YES;
    [self rebuildDrawingCache];
}

- (void)setColorByPersona:(BOOL)colorByPersona {
    _colorByPersona = colorByPersona;
    self.frameStructureDirty = YES;
    [self rebuildDrawingCache];
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
    // Physics runs on the graph's own queue; this timer only redraws from the
    // positions it publishes. Always poke the graph so a dirty structure syncs.
    [self.graph startSimulation];
    self.frameStructureDirty = YES;
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
    [self.graph stopSimulation];
}

- (void)simulationStep {
    if (!self.graph) return;

    [self.graph decayFlash];
    [self rebuildDrawingCache];

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

/// NSColor -> components under this view's effective appearance, so dynamic
/// system colors resolve to the right light/dark value.
- (ESScopeColor)scopeColorFor:(NSColor *)color {
    __block ESScopeColor out = { 0.5f, 0.5f, 0.5f, 1.0f };
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (c) {
            out.r = (float)c.redComponent; out.g = (float)c.greenComponent;
            out.b = (float)c.blueComponent; out.a = (float)c.alphaComponent;
        }
    }];
    return out;
}

/// Buffers that only change with the graph's structure or the color scheme:
/// node order, node colors, edge index pairs, edge alphas.
- (void)rebuildFrameStructure {
    self.frameStructureDirty = NO;
    NSArray<ESGraphNode *> *nodes = self.graph ? self.graph.visibleNodes : @[];
    self.frameNodes = nodes;
    [self.frameNodeIndex removeAllObjects];
    for (NSUInteger i = 0; i < nodes.count; i++) {
        [self.frameNodeIndex setObject:@(i) forKey:nodes[i]];
    }

    NSMutableData *colors = [NSMutableData dataWithLength:nodes.count * sizeof(ESScopeColor)];
    ESScopeColor *cbuf = colors.mutableBytes;
    if (self.colorByPersona) {
        NSMutableDictionary<NSString *, NSValue *> *byAuthor = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < nodes.count; i++) {
            NSString *key = nodes[i].author ?: @"";
            NSValue *v = byAuthor[key];
            if (!v) {
                ESScopeColor c = [self scopeColorFor:[ESMemoryScopeView colorForAuthor:nodes[i].author]];
                v = [NSValue valueWithBytes:&c objCType:@encode(ESScopeColor)];
                byAuthor[key] = v;
            }
            [v getValue:&cbuf[i] size:sizeof(ESScopeColor)];
        }
    } else {
        ESColorLUT *lut = self.colorLUT;
        ESScopeColor table[256];
        BOOL have[256] = { NO };
        ESScopeColor fallback = [self scopeColorFor:NSColor.controlAccentColor];
        for (NSUInteger i = 0; i < nodes.count; i++) {
            CGFloat heat = fmin(fmax(nodes[i].heat, 0.0), 1.0);
            NSUInteger q = (NSUInteger)lrint(heat * 255.0);
            if (!have[q]) {
                table[q] = lut ? [self scopeColorFor:[lut colorForValue:(CGFloat)q / 255.0]] : fallback;
                have[q] = YES;
            }
            cbuf[i] = table[q];
        }
    }
    self.frameNodeColors = colors;

    NSArray<ESGraphEdge *> *edges = self.graph ? self.graph.visibleEdges : @[];
    CGFloat maxSimWeight = 0.0;
    for (ESGraphEdge *edge in edges) {
        if (!edge.isExplicitLink && edge.weight > maxSimWeight) maxSimWeight = edge.weight;
    }
    if (maxSimWeight <= 0.0) maxSimWeight = 1.0;

    NSMutableData *idx = [NSMutableData dataWithCapacity:edges.count * 2 * sizeof(uint32_t)];
    NSMutableData *alpha = [NSMutableData dataWithCapacity:edges.count * sizeof(float)];
    NSMutableData *isLink = [NSMutableData dataWithCapacity:edges.count];
    NSUInteger count = 0;
    const CGFloat maxAlpha = 0.7;   // similarity edges: sqrt-normalized weight, as before
    for (ESGraphEdge *edge in edges) {
        NSNumber *a = edge.source ? [self.frameNodeIndex objectForKey:edge.source] : nil;
        NSNumber *b = edge.target ? [self.frameNodeIndex objectForKey:edge.target] : nil;
        if (!a || !b) continue;
        uint32_t pair[2] = { (uint32_t)a.unsignedIntegerValue, (uint32_t)b.unsignedIntegerValue };
        [idx appendBytes:pair length:sizeof(pair)];
        float al = edge.isExplicitLink ? 1.0f : (float)(sqrt(edge.weight / maxSimWeight) * maxAlpha);
        [alpha appendBytes:&al length:sizeof(al)];
        uint8_t link = edge.isExplicitLink ? 1 : 0;
        [isLink appendBytes:&link length:1];
        count++;
    }
    self.frameEdgeIndices = idx;
    self.frameEdgeAlpha = alpha;
    self.frameEdgeIsLink = isLink;
    self.frameEdgeCount = count;
}

/// Resolve the transform (auto-fit or user), snapshot the per-frame state and
/// hand it to the renderer. Kept under its historical name: the controller and
/// the gestures call it wherever a redraw is wanted.
- (void)rebuildDrawingCache {
    if (!self.graph) return;

    if (!self.hasUserTransform) {
        CGFloat scale; CGPoint offset;
        [self computeAutoFitScale:&scale offset:&offset];
        self.viewScale  = scale;
        self.viewOffset = offset;
    }

    CFAbsoluteTime tAssemble = CFAbsoluteTimeGetCurrent();
    if (self.frameStructureDirty) [self rebuildFrameStructure];

    NSArray<ESGraphNode *> *nodes = self.frameNodes;
    NSUInteger n = nodes.count;
    self.lastNodeCount = n;

    ESScopeFrame *frame = [ESScopeFrame new];
    frame.nodeCount = n;
    NSMutableData *positions = [NSMutableData dataWithLength:n * sizeof(CGPoint)];
    NSMutableData *flash = [NSMutableData dataWithLength:n * sizeof(float)];
    CGPoint *p = positions.mutableBytes;
    float *fl = flash.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        ESGraphNode *node = nodes[i];
        p[i] = node.position;
        fl[i] = (float)node.flashIntensity;
    }
    frame.positions = positions;
    frame.flash = flash;
    frame.nodeColors = self.frameNodeColors;
    frame.edgeCount = self.frameEdgeCount;
    frame.edgeIndices = self.frameEdgeIndices;
    frame.edgeAlpha = self.frameEdgeAlpha;
    frame.edgeIsLink = self.frameEdgeIsLink;

    frame.scale = self.viewScale;
    frame.offset = self.viewOffset;
    frame.sizePoints = self.bounds.size;
    frame.backingScale = self.window ? self.window.backingScaleFactor : 2.0;
    CGFloat r = kNodeRadius * self.viewScale;
    if (r < 3.0) r = 3.0;
    if (r > 12.0) r = 12.0;
    frame.nodeRadius = r;

    NSNumber *sel = (self.selectedNode && self.selectedNode.visible)
        ? [self.frameNodeIndex objectForKey:self.selectedNode] : nil;
    frame.selectedIndex = sel ? (NSInteger)sel.unsignedIntegerValue : -1;
    frame.backgroundColor = [self scopeColorFor:NSColor.windowBackgroundColor];
    frame.linkColor = [self scopeColorFor:[NSColor.separatorColor colorWithAlphaComponent:0.8]];
    frame.similarityColor = [self scopeColorFor:NSColor.separatorColor];
    frame.accentColor = [self scopeColorFor:NSColor.controlAccentColor];

    self.statAssembleMs += (CFAbsoluteTimeGetCurrent() - tAssemble) * 1000.0;
    self.statSubmitted++;
    CFAbsoluteTime tSubmit = CFAbsoluteTimeGetCurrent();

    __weak typeof(self) weakSelf = self;
    [self.renderer renderFrame:frame completion:^(CGImageRef image, ESScopeRenderStats *stats, NSUInteger dropped) {
        typeof(self) self = weakSelf;
        if (!self || !image) return;
        if (self.latestImage) CGImageRelease(self.latestImage);
        self.latestImage = CGImageRetain(image);
        self.statCompleted++;
        self.statDropped += dropped;
        self.statRasterMs += stats.totalMs;
        double latency = (CFAbsoluteTimeGetCurrent() - tSubmit) * 1000.0;
        self.statLatencyMs += latency;
        if (latency > self.statMaxLatencyMs) self.statMaxLatencyMs = latency;
        self.statLast = stats;
        [self setNeedsDisplay:YES];   // -> updateLayer
        [self logStatsIfDue];
    }];
}

#pragma mark - Layer

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    CGFloat bs = self.window ? self.window.backingScaleFactor : 2.0;
    self.layer.contentsScale = bs;
    if (self.latestImage && self.lastNodeCount > 0) {
        self.layer.contents = (__bridge id)self.latestImage;
        return;
    }
    self.layer.contents = (__bridge id)[self emptyStateImageWithScale:bs];
}

/// Background plus "No entries yet", drawn on main (text needs AppKit).
- (CGImageRef)emptyStateImageWithScale:(CGFloat)bs {
    static CGImageRef cached = NULL;
    static CGSize cachedSize = { 0, 0 };
    static CGFloat cachedScale = 0;
    CGSize size = self.bounds.size;
    if (cached && CGSizeEqualToSize(size, cachedSize) && bs == cachedScale) return cached;
    if (cached) { CGImageRelease(cached); cached = NULL; }
    size_t w = (size_t)ceil(size.width * bs), h = (size_t)ceil(size.height * bs);
    if (w == 0 || h == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextScaleCTM(ctx, bs, bs);
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    [NSColor.windowBackgroundColor set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightLight],
        NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
        NSParagraphStyleAttributeName: style,
    };
    NSString *msg = @"No entries yet";
    NSSize sz = [msg sizeWithAttributes:attrs];
    [msg drawAtPoint:NSMakePoint((size.width - sz.width) * 0.5, (size.height - sz.height) * 0.5) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    cached = CGBitmapContextCreateImage(ctx);
    cachedSize = size; cachedScale = bs;
    CGContextRelease(ctx);
    return cached;
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self rebuildDrawingCache];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.frameStructureDirty = YES;
    [self rebuildDrawingCache];
}

#pragma mark - Instrumentation

- (void)logStatsIfDue {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.statWindowStart == 0) { self.statWindowStart = now; return; }
    if (now - self.statWindowStart < 1.0) return;
    NSUInteger done = MAX(self.statCompleted, (NSUInteger)1);
    ESScopeRenderStats *r = self.statLast;
    ESLog(@"[Scope] submitted %lu rendered %lu dropped %lu | assemble %.1f ms/frame | raster %.1f ms/frame (edges %.1f, nodes %.1f) | latency avg %.0f max %.0f ms | %lu nodes %lu edges drawn at %lux%lu",
          (unsigned long)self.statSubmitted, (unsigned long)self.statCompleted, (unsigned long)self.statDropped,
          self.statAssembleMs / MAX(self.statSubmitted, (NSUInteger)1),
          self.statRasterMs / done, r.edgeMs, r.nodeMs, self.statLatencyMs / done, self.statMaxLatencyMs,
          (unsigned long)r.nodesDrawn, (unsigned long)r.edgesDrawn, (unsigned long)r.pixelsW, (unsigned long)r.pixelsH);
    self.statWindowStart = now;
    self.statAssembleMs = self.statRasterMs = self.statLatencyMs = self.statMaxLatencyMs = 0;
    self.statSubmitted = self.statCompleted = self.statDropped = 0;
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
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [self stopSimulation];
    } else {
        [self rebuildDrawingCache];
    }
}

#pragma mark - View Lifecycle

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
