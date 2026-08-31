//
//  ESTagCloudView.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Tag cloud visualization driven by CDTag entities.
/// Owns its own FRC; layout computed via Archimedean spiral placement.
@interface ESTagCloudView : NSView

/// Rebuild layout from current Core Data state.
- (void)rebuildLayout;

@end

NS_ASSUME_NONNULL_END
