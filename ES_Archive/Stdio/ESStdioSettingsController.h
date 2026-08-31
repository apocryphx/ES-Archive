//
//  ESStdioSettingsController.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  The app-settings pane for the stdio host. Reuses ESApplicationSettingsController's
//  ESAppConfig-backed logic (Dock vs Menu-bar mode, launch-at-login, show-main-window)
//  but supplies the view PROGRAMMATICALLY — the stdio target ships no storyboard, and
//  its windows are hand-built (cf. ESOnboardingWindowController). An activation-mode
//  change is applied on the NEXT session rather than relaunching, because a
//  Claude-spawned host is a piped process and relaunching would sever the session.
//

#import "ESApplicationSettingsController.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESStdioSettingsController : ESApplicationSettingsController

/// Present the settings window (creating it once), bringing the app forward.
+ (void)showSettings;

@end

NS_ASSUME_NONNULL_END
