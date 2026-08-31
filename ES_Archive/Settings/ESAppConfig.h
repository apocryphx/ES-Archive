//
//  ESAppConfig.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Centralized access to app-level preferences: activation mode,
//  launch-at-login, and whether the dashboard opens on launch.
//  Mirrors the ESServerConfig pattern.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESActivationMode) {
    ESActivationModeDock    = 0, // regular Dock app (default)
    ESActivationModeMenuBar = 1, // background service, menu-bar only
};

@interface ESAppConfig : NSObject

+ (ESActivationMode)activationMode;
+ (void)setActivationMode:(ESActivationMode)mode;

/// Whether the app auto-starts on user login. Backed by SMAppService.
+ (BOOL)launchAtLogin;

/// Register or unregister with SMAppService. Returns NO on failure and populates `error`.
+ (BOOL)setLaunchAtLogin:(BOOL)enabled error:(NSError **)error;

+ (BOOL)showMainWindowAtLaunch;
+ (void)setShowMainWindowAtLaunch:(BOOL)show;

@end

NS_ASSUME_NONNULL_END
