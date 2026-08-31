//
//  ESAppConfig.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESAppConfig.h"
#import <ServiceManagement/ServiceManagement.h>

static NSString * const kDefaultsActivationMode        = @"ESActivationMode";
static NSString * const kDefaultsShowMainWindowAtLaunch = @"ESShowMainWindowAtLaunch";

@implementation ESAppConfig

+ (void)initialize {
    if (self == [ESAppConfig class]) {
        // Default values preserve the app's current behavior: Dock app with
        // the dashboard open on launch. Launch-at-login state is owned by
        // SMAppService, not NSUserDefaults.
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kDefaultsActivationMode        : @(ESActivationModeDock),
            kDefaultsShowMainWindowAtLaunch : @YES,
        }];
    }
}

#pragma mark - Activation mode

+ (ESActivationMode)activationMode {
    return (ESActivationMode)[[NSUserDefaults standardUserDefaults] integerForKey:kDefaultsActivationMode];
}

+ (void)setActivationMode:(ESActivationMode)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kDefaultsActivationMode];
}

#pragma mark - Launch at login

+ (BOOL)launchAtLogin {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

+ (BOOL)setLaunchAtLogin:(BOOL)enabled error:(NSError **)error {
    SMAppService *service = SMAppService.mainAppService;
    NSError *innerErr = nil;
    BOOL ok = enabled
        ? [service registerAndReturnError:&innerErr]
        : [service unregisterAndReturnError:&innerErr];
    if (!ok && error) *error = innerErr;
    return ok;
}

#pragma mark - Show main window at launch

+ (BOOL)showMainWindowAtLaunch {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDefaultsShowMainWindowAtLaunch];
}

+ (void)setShowMainWindowAtLaunch:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:kDefaultsShowMainWindowAtLaunch];
}

@end
