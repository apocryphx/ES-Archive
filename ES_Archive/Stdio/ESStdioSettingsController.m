//
//  ESStdioSettingsController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioSettingsController.h"

@implementation ESStdioSettingsController

// The view itself now comes from the base class's -loadView — it was promoted
// there so the Server app stops getting these controls from a storyboard scene.
// All this subclass still changes is what an activation-mode change does.

/// Apply on next session. The base -apply: has ALREADY persisted the new mode to
/// ESAppConfig by the time it calls this; we simply do NOT relaunch (a piped,
/// Claude-spawned host can't be relaunched without severing the session). The next
/// spawned host reads the new mode; the current window keeps its present mode.
- (void)promptRelaunch {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = @"Applied to the next session";
    a.informativeText = @"The Dock / Menu-bar change is saved and takes effect for the next "
                        @"ES Archive session. The current window keeps its present mode.";
    [a addButtonWithTitle:@"OK"];
    if (self.view.window) {
        [a beginSheetModalForWindow:self.view.window completionHandler:nil];
    } else {
        [a runModal];
    }
}

#pragma mark - Presentation

+ (void)showSettings {
    static NSWindowController *wc;
    if (!wc) {
        ESStdioSettingsController *vc = [[ESStdioSettingsController alloc] init];
        NSWindow *win = [NSWindow windowWithContentViewController:vc];
        win.title = @"ES Archive Settings";
        win.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        win.releasedWhenClosed = NO;
        [win center];
        wc = [[NSWindowController alloc] initWithWindow:win];
    }
    // Accessory (Minimal) apps open panels behind the frontmost app unless activated.
    [NSApp activateIgnoringOtherApps:YES];
    [wc showWindow:nil];   // -viewWillAppear reloads from ESAppConfig on each show
}

@end
