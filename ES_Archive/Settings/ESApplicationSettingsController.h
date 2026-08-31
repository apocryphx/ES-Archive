//
//  ESApplicationSettingsController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Created by Kolja Wawrowsky on 4/20/26.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The UI Settings pane, shared by both apps. The view is built in code by
/// -loadView — there is no NIB and no storyboard scene. Subclasses override
/// -promptRelaunch to choose what an activation-mode change does (see
/// ESStdioSettingsController, which applies to the next session instead of
/// relaunching a piped host).
@interface ESApplicationSettingsController : NSViewController

// Activation-mode radio pair (Dock / Menu-bar only)
@property (nonatomic, strong) NSButton *dockModeRadio;
@property (nonatomic, strong) NSButton *menuBarModeRadio;

// Launch behavior checkboxes
@property (nonatomic, strong) NSButton *launchAtLoginCheckbox;
@property (nonatomic, strong) NSButton *showMainWindowCheckbox;

// Action
@property (nonatomic, strong) NSButton *applyButton;

/// Hook for subclasses: what an activation-mode change should do once -apply:
/// has already persisted it. The base implementation offers a relaunch.
- (void)promptRelaunch;

@end

NS_ASSUME_NONNULL_END
