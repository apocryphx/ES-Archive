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
/// Reloads on view-context changes that touch tags; layout computed via
/// Archimedean spiral placement.
@interface ESTagCloudView : NSView

/// The persona (author) whose memories are counted. nil = All (witness):
/// every persona's memories together. Setting it reloads the cloud.
@property (nonatomic, copy, nullable) NSString *persona;

/// Re-read tag counts from Core Data and lay them out again.
- (void)reloadTags;

@end

NS_ASSUME_NONNULL_END
