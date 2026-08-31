//
//  ESMemoryScopeWindowController.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

/// Window controller for the Archive Scope visualization.
/// Phase 1: simple window with graph view + status bar.
@interface ESMemoryScopeWindowController : NSWindowController

+ (instancetype)shared;
- (void)showWindow:(id)sender;

@end
