//
//  ESApplicationSettingsController.m
//  ES Archive MCP
//
//  Created by Kolja Wawrowsky on 4/20/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESApplicationSettingsController.h"
#import "ESAppConfig.h"
#import "NSViewController+ESUIHelpers.h"

@implementation ESApplicationSettingsController

#pragma mark - View

/// Build the pane in code — promoted here from ESStdioSettingsController so both
/// apps share one implementation. It used to come from a storyboard scene in the
/// Server app and from code in the MCP app, and that asymmetry is exactly where
/// the July 27 empty-Settings-pane bug lived: the merge carried a stripped scene
/// through without a conflict, the class compiled, the outlets were nil, and
/// nothing anywhere reported an error.
///
/// Auto Layout rather than the fixed frames the stdio version used: the Server
/// app hosts this in ESSettingsTabViewController, which sizes the window to each
/// pane's -fittingSize, and a fixed-frame view reports zero. The width constraint
/// and the bottom anchor are what make that size resolve — same pattern as the
/// sibling Personas and Ports panes.
///
/// -configUI (below) sets every title, target and action, so this only creates
/// and places the controls.
- (void)loadView {
    self.title = @"UI Settings";

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 220)];

    NSTextField *appearanceHeader = [NSTextField labelWithString:@"Appearance"];
    appearanceHeader.font = [NSFont boldSystemFontOfSize:13];

    // Radios share a superview + action ⇒ AppKit auto-groups them (mutually exclusive).
    self.dockModeRadio    = [NSButton radioButtonWithTitle:@"" target:nil action:NULL];
    self.menuBarModeRadio = [NSButton radioButtonWithTitle:@"" target:nil action:NULL];

    NSTextField *startupHeader = [NSTextField labelWithString:@"Startup"];
    startupHeader.font = [NSFont boldSystemFontOfSize:13];

    self.launchAtLoginCheckbox  = [NSButton checkboxWithTitle:@"" target:nil action:NULL];
    self.showMainWindowCheckbox = [NSButton checkboxWithTitle:@"" target:nil action:NULL];

    self.applyButton = [NSButton buttonWithTitle:@"" target:nil action:NULL];
    self.applyButton.bezelStyle = NSBezelStyleRounded;

    NSArray<NSView *> *all = @[appearanceHeader, self.dockModeRadio, self.menuBarModeRadio,
                               startupHeader, self.launchAtLoginCheckbox,
                               self.showMainWindowCheckbox, self.applyButton];
    for (NSView *v in all) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }

    CGFloat m = 20;

    // The preferred size, held at high-but-not-required priority. -fittingSize
    // still reports 360 × compact, so the tab controller sizes the window to it,
    // but if the pane is ever handed a larger frame anyway it stretches and
    // top-aligns instead of AppKit breaking one of the required spacings below
    // and spreading the controls down the window.
    NSLayoutConstraint *width  = [root.widthAnchor constraintEqualToConstant:360];
    NSLayoutConstraint *bottom = [self.applyButton.bottomAnchor constraintEqualToAnchor:root.bottomAnchor
                                                                              constant:-m];
    width.priority = bottom.priority = NSLayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        width, bottom,

        [appearanceHeader.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [appearanceHeader.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [appearanceHeader.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],

        [self.dockModeRadio.topAnchor constraintEqualToAnchor:appearanceHeader.bottomAnchor constant:8],
        [self.dockModeRadio.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [self.menuBarModeRadio.topAnchor constraintEqualToAnchor:self.dockModeRadio.bottomAnchor constant:6],
        [self.menuBarModeRadio.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [startupHeader.topAnchor constraintEqualToAnchor:self.menuBarModeRadio.bottomAnchor constant:18],
        [startupHeader.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [startupHeader.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],

        [self.launchAtLoginCheckbox.topAnchor constraintEqualToAnchor:startupHeader.bottomAnchor constant:8],
        [self.launchAtLoginCheckbox.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [self.showMainWindowCheckbox.topAnchor constraintEqualToAnchor:self.launchAtLoginCheckbox.bottomAnchor constant:6],
        [self.showMainWindowCheckbox.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [self.applyButton.topAnchor constraintEqualToAnchor:self.showMainWindowCheckbox.bottomAnchor constant:20],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
    ]];

    self.view = root;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self configUI];
    [self reloadFromConfig];
    [self updateApplyEnabled];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    // Pick up external changes (e.g. user toggled Login Items in System Settings
    // while the window was hidden).
    [self reloadFromConfig];
    [self updateApplyEnabled];
}

#pragma mark - UI

- (void)configUI {
    // Activation mode radios — share superview + action → AppKit auto-groups.
    _dockModeRadio.title    = @"Dock app";
    _dockModeRadio.target   = self;
    _dockModeRadio.action   = @selector(controlChanged:);

    _menuBarModeRadio.title  = @"Menu bar only";
    _menuBarModeRadio.target = self;
    _menuBarModeRadio.action = @selector(controlChanged:);

    _launchAtLoginCheckbox.title  = @"Launch at login";
    _launchAtLoginCheckbox.target = self;
    _launchAtLoginCheckbox.action = @selector(controlChanged:);

    _showMainWindowCheckbox.title  = @"Show main window at launch";
    _showMainWindowCheckbox.target = self;
    _showMainWindowCheckbox.action = @selector(controlChanged:);

    _applyButton.title          = @"Apply";
    _applyButton.target         = self;
    _applyButton.action         = @selector(apply:);
    _applyButton.keyEquivalent  = @"\r";
}

#pragma mark - Load / Save

- (void)reloadFromConfig {
    ESActivationMode mode = [ESAppConfig activationMode];
    self.dockModeRadio.state    = (mode == ESActivationModeDock)    ? NSControlStateValueOn : NSControlStateValueOff;
    self.menuBarModeRadio.state = (mode == ESActivationModeMenuBar) ? NSControlStateValueOn : NSControlStateValueOff;

    self.launchAtLoginCheckbox.state  = [ESAppConfig launchAtLogin]          ? NSControlStateValueOn : NSControlStateValueOff;
    self.showMainWindowCheckbox.state = [ESAppConfig showMainWindowAtLaunch] ? NSControlStateValueOn : NSControlStateValueOff;
}

#pragma mark - Form state

- (ESActivationMode)selectedActivationMode {
    return (self.menuBarModeRadio.state == NSControlStateValueOn)
         ? ESActivationModeMenuBar : ESActivationModeDock;
}

- (BOOL)isFormDirty {
    if ([self selectedActivationMode] != [ESAppConfig activationMode]) return YES;
    BOOL launch = (self.launchAtLoginCheckbox.state  == NSControlStateValueOn);
    BOOL show   = (self.showMainWindowCheckbox.state == NSControlStateValueOn);
    if (launch != [ESAppConfig launchAtLogin])          return YES;
    if (show   != [ESAppConfig showMainWindowAtLaunch]) return YES;
    return NO;
}

- (void)updateApplyEnabled {
    self.applyButton.enabled = [self isFormDirty];
}

#pragma mark - Actions

- (void)controlChanged:(id)sender {
    [self updateApplyEnabled];
}

- (void)apply:(id)sender {
    if (![self isFormDirty]) return;

    ESActivationMode newMode      = [self selectedActivationMode];
    ESActivationMode oldMode      = [ESAppConfig activationMode];
    BOOL newLaunch                = (self.launchAtLoginCheckbox.state  == NSControlStateValueOn);
    BOOL oldLaunch                = [ESAppConfig launchAtLogin];
    BOOL newShow                  = (self.showMainWindowCheckbox.state == NSControlStateValueOn);

    // Persist straightforward defaults.
    [ESAppConfig setActivationMode:newMode];
    [ESAppConfig setShowMainWindowAtLaunch:newShow];

    // Launch-at-login is owned by SMAppService; toggle only on change so we
    // don't repeatedly register/unregister on every Apply.
    if (newLaunch != oldLaunch) {
        NSError *err = nil;
        if (![ESAppConfig setLaunchAtLogin:newLaunch error:&err]) {
            // Revert the checkbox so the UI reflects reality.
            self.launchAtLoginCheckbox.state = oldLaunch ? NSControlStateValueOn : NSControlStateValueOff;
            [self es_presentWarningTitle:@"Couldn't update Login Items"
                            message:err.localizedDescription ?: @"SMAppService failed."];
        }
    }

    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateApplyEnabled];

    // Activation mode change requires a relaunch — setActivationPolicy: mid-flight
    // is unreliable.
    if (newMode != oldMode) {
        [self promptRelaunch];
    }
}

#pragma mark - Relaunch

- (void)promptRelaunch {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = @"Relaunch required";
    a.informativeText = @"The activation-mode change will take effect after ES Archive relaunches.";
    [a addButtonWithTitle:@"Quit & Reopen"];
    [a addButtonWithTitle:@"Later"];

    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) {
            [self es_relaunchApplication];
        }
    };
    if (parent) {
        [a beginSheetModalForWindow:parent completionHandler:handle];
    } else {
        handle([a runModal]);
    }
}

#pragma mark - Helpers

@end
