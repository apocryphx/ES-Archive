//
//  ESScopeRenderer.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESScopeRenderer.h"
#import <math.h>

// Measured (M4 Max, 3600x2400): Core Graphics scan-converts a path's whole
// bounding box per fill/stroke call, so one canvas-wide path holding many small
// subpaths costs 100s of ms while the same marks drawn one call each cost a few
// microseconds apiece. Every primitive is drawn individually.
static const CGFloat kLineWidthLink = 2.0;
static const CGFloat kLineWidthSimilarity = 0.5;

@implementation ESScopeFrame
@end

@implementation ESScopeRenderStats
@end

static inline double ESNowMs(void) { return CFAbsoluteTimeGetCurrent() * 1000.0; }

@implementation ESScopeRenderer {
    dispatch_queue_t _queue;
    ESScopeFrame *_pending;
    NSUInteger _droppedSincePending;
    BOOL _busy;
    NSLock *_lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.esarchive.scope.renderer", DISPATCH_QUEUE_SERIAL);
        _lock = [NSLock new];
    }
    return self;
}

- (void)renderFrame:(ESScopeFrame *)frame
         completion:(void (^)(CGImageRef, ESScopeRenderStats *, NSUInteger))completion {
    [_lock lock];
    if (_busy) {
        if (_pending) _droppedSincePending++;
        _pending = frame;
        [_lock unlock];
        return;
    }
    _busy = YES;
    [_lock unlock];
    [self enqueue:frame dropped:0 completion:completion];
}

- (void)enqueue:(ESScopeFrame *)frame dropped:(NSUInteger)dropped
     completion:(void (^)(CGImageRef, ESScopeRenderStats *, NSUInteger))completion {
    dispatch_async(_queue, ^{
        ESScopeRenderStats *stats = [ESScopeRenderStats new];
        CGImageRef image = [ESScopeRenderer rasterize:frame stats:stats];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image, stats, dropped);
            if (image) CGImageRelease(image);
        });
        [self->_lock lock];
        ESScopeFrame *next = self->_pending;
        NSUInteger nextDropped = self->_droppedSincePending;
        self->_pending = nil;
        self->_droppedSincePending = 0;
        if (!next) self->_busy = NO;
        [self->_lock unlock];
        if (next) [self enqueue:next dropped:nextDropped completion:completion];
    });
}

#pragma mark - Rasterization (renderer queue)

+ (CGImageRef)rasterize:(ESScopeFrame *)f stats:(ESScopeRenderStats *)st {
    double t0 = ESNowMs();
    size_t w = (size_t)ceil(f.sizePoints.width * f.backingScale);
    size_t h = (size_t)ceil(f.sizePoints.height * f.backingScale);
    if (w == 0 || h == 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    st.pixelsW = w; st.pixelsH = h;

    // Opaque background first (layer contents are y-up; fill before flipping).
    ESScopeColor bg = f.backgroundColor;
    CGContextSetRGBFillColor(ctx, bg.r, bg.g, bg.b, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));

    // The view is flipped (y down). Layer contents are y-up, so flip the CTM:
    // view point (x, y) lands at pixel row h - y*scale, top of the image = y 0.
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, f.backingScale, -f.backingScale);

    const CGPoint *pos = f.positions.bytes;
    const ESScopeColor *colors = f.nodeColors.bytes;
    const float *flash = f.flash.bytes;
    NSUInteger n = f.nodeCount;
    CGFloat s = f.scale, ox = f.offset.x, oy = f.offset.y;
    CGFloat r = f.nodeRadius;

    // Visible window in view points, with a margin; everything else is culled.
    CGFloat margin = fmax(r, 2.0) + 2.0;
    CGFloat minX = -margin, minY = -margin;
    CGFloat maxX = f.sizePoints.width + margin, maxY = f.sizePoints.height + margin;

    // --- Edges: one stroke per segment ---
    if (f.edgeCount > 0 && n > 0) {
        double t = ESNowMs();
        const uint32_t *idx = f.edgeIndices.bytes;
        const float *alpha = f.edgeAlpha.bytes;
        const uint8_t *isLink = f.edgeIsLink.bytes;
        ESScopeColor sc = f.similarityColor, lc = f.linkColor;
        BOOL linkMode = NO;
        CGContextSetLineWidth(ctx, kLineWidthSimilarity);
        for (NSUInteger e = 0; e < f.edgeCount; e++) {
            uint32_t a = idx[e * 2], b = idx[e * 2 + 1];
            if (a >= n || b >= n) continue;
            CGPoint p[2] = {
                { pos[a].x * s + ox, pos[a].y * s + oy },
                { pos[b].x * s + ox, pos[b].y * s + oy },
            };
            // Level of detail: draw an edge only if at least one endpoint is in
            // the window. Edges that merely pass through (both nodes off-screen)
            // are the mesh that swamps a zoomed-in view of a large persona.
            BOOL aIn = (p[0].x >= minX && p[0].x <= maxX && p[0].y >= minY && p[0].y <= maxY);
            BOOL bIn = (p[1].x >= minX && p[1].x <= maxX && p[1].y >= minY && p[1].y <= maxY);
            if (!aIn && !bIn) { st.edgesSkipped++; continue; }
            if (isLink[e]) {
                if (!linkMode) { CGContextSetLineWidth(ctx, kLineWidthLink); linkMode = YES; }
                CGContextSetRGBStrokeColor(ctx, lc.r, lc.g, lc.b, lc.a);
            } else {
                if (linkMode) { CGContextSetLineWidth(ctx, kLineWidthSimilarity); linkMode = NO; }
                float al = alpha[e];
                if (al < 0) al = 0;
                if (al > 1) al = 1;
                CGContextSetRGBStrokeColor(ctx, sc.r, sc.g, sc.b, al);
            }
            CGContextStrokeLineSegments(ctx, p, 2);
            st.edgesDrawn++;
        }
        st.edgeMs = ESNowMs() - t;
    }

    // --- Nodes: one fill each; sub-pixel nodes as squares ---
    if (n > 0) {
        double t = ESNowMs();
        BOOL tiny = (r < 1.25);
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat x = pos[i].x * s + ox, y = pos[i].y * s + oy;
            if (x < minX || x > maxX || y < minY || y > maxY) continue;
            ESScopeColor c = colors[i];
            float fl = flash ? flash[i] : 0.0f;
            if (fl > 0.01f) { c.r += (1 - c.r) * fl; c.g += (1 - c.g) * fl; c.b += (1 - c.b) * fl; }
            CGContextSetRGBFillColor(ctx, c.r, c.g, c.b, c.a);
            CGRect rect = CGRectMake(x - r, y - r, r * 2, r * 2);
            if (tiny) CGContextFillRect(ctx, rect);
            else      CGContextFillEllipseInRect(ctx, rect);
            st.nodesDrawn++;
        }
        st.nodeMs = ESNowMs() - t;
    }

    // --- Selection ring ---
    if (f.selectedIndex >= 0 && (NSUInteger)f.selectedIndex < n) {
        NSUInteger i = (NSUInteger)f.selectedIndex;
        CGFloat x = pos[i].x * s + ox, y = pos[i].y * s + oy;
        CGFloat ringR = r + 4.0;
        ESScopeColor ac = f.accentColor;
        CGContextSetLineWidth(ctx, 2.0);
        CGContextSetRGBStrokeColor(ctx, ac.r, ac.g, ac.b, ac.a);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(x - ringR, y - ringR, ringR * 2, ringR * 2));
    }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    st.totalMs = ESNowMs() - t0;
    return image;
}

@end
