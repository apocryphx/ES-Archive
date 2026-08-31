//
//  ESMemoryScopeView.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

@class ESForceGraph, ESGraphNode, ESColorLUT, ESMemoryScopeView, ESMemoryScopeDataSource;

NS_ASSUME_NONNULL_BEGIN

/// Delegate notified when the user selects a node by clicking.
@protocol ESMemoryScopeViewDelegate <NSObject>
@optional
- (void)memoryScopeView:(ESMemoryScopeView *)view didSelectNode:(nullable ESGraphNode *)node;
@end

/// Renders the force graph with a pre-built drawing cache.
/// Supports scroll-wheel zoom, trackpad pinch, click-drag pan, and auto-fit.
@interface ESMemoryScopeView : NSView

@property (nonatomic, strong) ESForceGraph *graph;
@property (nonatomic, strong) ESColorLUT *colorLUT;
/// When YES, nodes are colored by persona (author) instead of by heat — used
/// in All (witness) mode so the personas read as distinct clusters. When NO,
/// the heat LUT applies (one persona's access-frequency landscape).
@property (nonatomic) BOOL colorByPersona;
@property (nonatomic, weak, nullable) id<ESMemoryScopeViewDelegate> delegate;
@property (nonatomic, weak, nullable) ESMemoryScopeDataSource *dataSource;
@property (nonatomic, weak, nullable) ESGraphNode *selectedNode;

/// Start the simulation display link / timer.
- (void)startSimulation;

/// Stop the simulation timer.
- (void)stopSimulation;

/// Rebuild the drawing cache from current graph state.
- (void)rebuildDrawingCache;

/// Reset zoom/pan to auto-fit the graph in the view.
- (void)resetToFit;

@end

NS_ASSUME_NONNULL_END
