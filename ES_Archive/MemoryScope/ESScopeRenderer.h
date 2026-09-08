//
//  ESScopeRenderer.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Off-main rasterization of an Archive Scope frame into a CGImage that the
//  view assigns to its own layer's contents from -updateLayer. The view fills
//  an ESScopeFrame with plain buffers on main; nothing here touches AppKit,
//  the graph, or Core Data.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// RGBA, straight (non-premultiplied) alpha, device RGB.
typedef struct { float r, g, b, a; } ESScopeColor;

@interface ESScopeFrame : NSObject
// Nodes (nodeCount entries each); positions in graph space.
@property (nonatomic) NSUInteger nodeCount;
@property (nonatomic, strong) NSData *positions;     // CGPoint[nodeCount]
@property (nonatomic, strong) NSData *nodeColors;    // ESScopeColor[nodeCount]
@property (nonatomic, strong) NSData *flash;         // float[nodeCount], 0 = none
// Edges as node-index pairs.
@property (nonatomic) NSUInteger edgeCount;
@property (nonatomic, strong) NSData *edgeIndices;   // uint32_t[edgeCount * 2]
@property (nonatomic, strong) NSData *edgeAlpha;     // float[edgeCount], similarity edges
@property (nonatomic, strong) NSData *edgeIsLink;    // uint8_t[edgeCount]
// Transform graph -> view points (view is flipped: y down), and the target.
@property (nonatomic) CGFloat scale;
@property (nonatomic) CGPoint offset;
@property (nonatomic) CGSize sizePoints;
@property (nonatomic) CGFloat backingScale;
@property (nonatomic) CGFloat nodeRadius;            // view points, already clamped
// Colors resolved on main under the view's appearance.
@property (nonatomic) ESScopeColor backgroundColor;
@property (nonatomic) ESScopeColor linkColor;
@property (nonatomic) ESScopeColor similarityColor;  // alpha replaced per edge
@property (nonatomic) ESScopeColor accentColor;      // selection ring
@property (nonatomic) NSInteger selectedIndex;       // -1 = none
@end

/// Where a frame spent its time, in milliseconds.
@interface ESScopeRenderStats : NSObject
@property (nonatomic) double totalMs, edgeMs, nodeMs;
@property (nonatomic) NSUInteger edgesDrawn, nodesDrawn, pixelsW, pixelsH;
@property (nonatomic) NSUInteger edgesSkipped;   // both endpoints off-screen
@end

@interface ESScopeRenderer : NSObject
/// Rasterize on a serial queue; completion runs on main with a +1 CGImage (or
/// NULL), the timings, and how many submitted frames were superseded before
/// this one. While a frame is in flight only the newest submission waits.
- (void)renderFrame:(ESScopeFrame *)frame
         completion:(void (^)(CGImageRef _Nullable image, ESScopeRenderStats *stats, NSUInteger dropped))completion;
@end

NS_ASSUME_NONNULL_END
