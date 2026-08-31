//
//  ESSettings.m
//  ES Archive MCP
//
//  Created by Kolja Wawrowsky on 4/20/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESSettingsTabViewController.h"
#import "ESApplicationSettingsController.h"
#import "ESAuthorConfigController.h"
#import "ESPortConfigController.h"

@interface ESSettingsTabViewController ()

@end

@implementation ESSettingsTabViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Settings";   // pinned — see -setTitle:

    // Every pane is built in code now — the storyboard no longer carries the tab
    // controller, its tabViewItems, or the UI Settings scene. Toolbar style is
    // set here because a programmatically created NSTabViewController defaults
    // to a segmented control on top; the storyboard used to declare it.
    self.tabStyle = NSTabViewControllerTabStyleToolbar;

    // UI Settings came from a storyboard scene wired to ESApplicationSettings-
    // Controller's outlets. That scene is gone: the controller builds its own
    // view, the same one the MCP app's ESStdioSettingsController shows.
    ESApplicationSettingsController *ui = [[ESApplicationSettingsController alloc] init];
    NSTabViewItem *uiTab = [NSTabViewItem tabViewItemWithViewController:ui];
    uiTab.label = @"UI Settings";
    if (@available(macOS 11.0, *)) {
        uiTab.image = [NSImage imageWithSystemSymbolName:@"macwindow"
                                accessibilityDescription:@"UI Settings"];
    }
    [self addTabViewItem:uiTab];

    // The legacy "Port Settings" tab was removed from the storyboard; its
    // responsibilities are now split across two code-built panes appended
    // here (no storyboard scenes needed): Personas manages the author list
    // (create / delete with records / rename / merge), Ports binds listening
    // ports to personas and holds the per-port JWT flag.
    ESAuthorConfigController *personas = [[ESAuthorConfigController alloc] init];
    NSTabViewItem *personaTab = [NSTabViewItem tabViewItemWithViewController:personas];
    personaTab.label = @"Personas";
    if (@available(macOS 11.0, *)) {
        personaTab.image = [NSImage imageWithSystemSymbolName:@"person.2"
                                     accessibilityDescription:@"Personas"];
    }
    [self addTabViewItem:personaTab];

    ESPortConfigController *ports = [[ESPortConfigController alloc] init];
    NSTabViewItem *portTab = [NSTabViewItem tabViewItemWithViewController:ports];
    portTab.label = @"Ports";
    if (@available(macOS 11.0, *)) {
        portTab.image = [NSImage imageWithSystemSymbolName:@"network"
                                  accessibilityDescription:@"Ports"];
    }
    [self addTabViewItem:portTab];

    // Check if the user has 'Reduce Transparency' enabled
    if (!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency) {
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] init];
        glass.style = NSGlassEffectViewStyleRegular;
        // Pinned with constraints rather than an autoresizing mask: this view is
        // laid out by AppKit's constraints, so a mask never fired and the glass
        // kept the bounds it was given at -viewDidLoad. Once the window resized
        // to a wider pane the glass stayed narrow, and the backing showed through
        // beside it — the content read as a split view rather than one surface.
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:glass positioned:NSWindowBelow relativeTo:nil];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        ]];
    }
    [self.view.window center];
}

- (void)viewDidAppear {
    [super viewDidAppear];

    // Only a tab *transition* resizes the window, so the pane that is selected
    // when the window first opens never gets one — the window keeps whatever
    // size -windowWithContentViewController: gave it, and the pane is stretched
    // to fill it: too wide leaves a gap beside the content, too tall forces
    // AppKit to break one of the pane's vertical spacings and the controls
    // spread apart. Size to the selected pane here instead. Unanimated — the
    // window is only just appearing, so there is nothing to animate from.
    NSTabViewItem *selected = self.tabViewItems[self.selectedTabViewItemIndex];
    [self resizeWindowToFitViewController:selected.viewController animated:NO];
}

/// NSTabViewController retitles itself to the selected pane on every tab change,
/// and the window title follows its contentViewController — so the window would
/// read "UI Settings", then "Personas", then "Ports" as you browse. The panes
/// keep their own titles (they're set in each -loadView and read elsewhere), so
/// pin the title here rather than stripping it from the children.
- (void)setTitle:(NSString *)title {
    [super setTitle:@"Settings"];
}

// Shared duration so the window resize and the view crossfade animate
// in lockstep. AppKit's default NSViewControllerTransitionCrossfade is
// around this mark — matching it keeps the two animations ending
// together so the window doesn't "catch up" to the new content.
static const NSTimeInterval kTabTransitionDuration = 0.25;

- (void)transitionFromViewController:(NSViewController *)fromViewController
                    toViewController:(NSViewController *)toViewController
                             options:(NSViewControllerTransitionOptions)options
                   completionHandler:(void (^)(void))completionHandler {

    NSViewControllerTransitionOptions modernOptions =
        options | NSViewControllerTransitionAllowUserInteraction;

    // Force layout on the incoming view so `fittingSize` reflects its
    // final intrinsic size before we compute the target window frame.
    [toViewController.view layoutSubtreeIfNeeded];

    // Kick off both animations inside a single NSAnimationContext group
    // with a shared duration — the window frame change animates in parallel
    // with the crossfade instead of snapping into place afterwards.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kTabTransitionDuration;
        [self resizeWindowToFitViewController:toViewController];
        [super transitionFromViewController:fromViewController
                           toViewController:toViewController
                                    options:modernOptions
                          completionHandler:completionHandler];
    }];
}

- (void)updateWindowFrameForViewController:(NSViewController *)viewController {
    [self resizeWindowToFitViewController:viewController];
}

- (void)resizeWindowToFitViewController:(NSViewController *)viewController {
    [self resizeWindowToFitViewController:viewController animated:YES];
}

- (void)resizeWindowToFitViewController:(NSViewController *)viewController
                               animated:(BOOL)animated {
    NSWindow *window = self.view.window;
    if (!window) return;

    // Force layout before reading fittingSize — on first appearance the pane may
    // not have been laid out yet, and an unlaid view reports a stale size.
    [viewController.view layoutSubtreeIfNeeded];
    NSSize targetSize = viewController.view.fittingSize;
    NSRect contentRect = NSMakeRect(0, 0, targetSize.width, targetSize.height);
    NSRect newWindowFrame = [window frameRectForContentRect:contentRect];

    // Keep the window's top-left corner pinned as the height changes.
    CGFloat heightDelta = window.frame.size.height - newWindowFrame.size.height;
    NSRect finalFrame = NSMakeRect(window.frame.origin.x,
                                   window.frame.origin.y + heightDelta,
                                   newWindowFrame.size.width,
                                   newWindowFrame.size.height);

    // Use the animator proxy so the frame change respects whatever
    // NSAnimationContext duration is active on the current thread. Outside
    // of an animation group this still animates with sensible defaults.
    if (animated) {
        [window.animator setFrame:finalFrame display:YES];
    } else {
        [window setFrame:finalFrame display:YES];
    }
}
@end
