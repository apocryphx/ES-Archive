//
//  AppDelegate.m
//  ES Archive
//
//  Created by Kolja Wawrowsky on 3/2/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "AppDelegate.h"
#import "ESLog.h"
#import "ESCoreDataStack.h"
#import "ESDeduplicator.h"
#import "ESVectorEngine.h"
#import "ESTagMigration.h"
#import "ESTagJanitor.h"
#import "ESDeduplicator.h"
#import "MCPServer.h"
#import "MCPUnixSocketServer.h"
#import "ESRequestScope.h"
#import "ESServerConfig.h"
#import "ESAppConfig.h"
#import "ESMenuBarController.h"
#import "ESSettingsTabViewController.h"
#import "ESSystemPulseViewController.h"
#import "ESMemoryScopeWindowController.h"
#import "ESHTTPConnectController.h"
#import "ESBackupCommands.h"
#import "ESMenuBuilder.h"
#import <signal.h>
#import <pwd.h>


@interface AppDelegate ( )

@property (strong) NSWindowController *settingsWindowController;
// nonatomic: it has a user-defined lazy getter below, which an atomic
// property can't pair with a synthesized setter.
@property (nonatomic, strong) NSWindowController *pulseWindowController;
@property (strong) ESMenuBarController *menuBarController;

- (void)installMainMenu;

@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // The main menu is built in code (see -installMainMenu) rather than loaded
    // from Main.storyboard. Install it here: the app hasn't presented yet, so
    // the menu bar is populated before it can ever be seen empty.
    [self installMainMenu];

    // Apply Accessory (menu-bar-only) policy here — not in +initialize.
    // +initialize runs while the main storyboard is still mid-load, which
    // causes AppKit to partially tear down the Main Menu (the standard
    // "ES Archive" app submenu ends up orphaned, triggering a "Internal
    // inconsistency in menus" warning on the console). By the time
    // -applicationWillFinishLaunching: fires the storyboard is fully loaded,
    // but the app hasn't presented yet — no visible Dock-icon flicker.
    if ([ESAppConfig activationMode] == ESActivationModeMenuBar) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

#pragma mark - Main menu

/// The Server app's menu bar, built in code — the MCP app's -installUserMainMenu
/// (ESStdioAppDelegate) is the template, and this is the first step in retiring
/// Main.storyboard. Storyboard XML merges silently and breaks invisibly; a menu
/// in code fails at compile time and diffs readably.
///
/// App (About · Settings ⌘, · Services · Hide · Quit ⌘Q), File (Back Up… ⇧⌘B ·
/// Restore… ⇧⌘R · Close Window ⌘W), Edit, View (Show Toolbar ⌥⌘T · Customize
/// Toolbar… · Enter Full Screen ⌃⌘F), Window (Show Dashboard · Show Memory
/// Scope · Minimize ⌘M · Zoom · Bring All to Front) and Help (ES Archive Help ⌘? ·
/// Connect ES Archive…).
///
/// Commands use the nil target, exactly like the storyboard's First-Responder
/// connections did: AppKit routes them up the responder chain to this delegate,
/// the same handlers the menu-bar status item reaches by targeting the delegate
/// directly (ESMenuBarController). Unlike the storyboard menu, this one leaves
/// auto-enabling on, so window-scoped items disable themselves when no window is
/// key instead of beeping.
- (void)installMainMenu {
    NSString *appName = NSRunningApplication.currentApplication.localizedName ?: @"ES Archive";
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // ── Application menu ──
    [ESMenuBuilder addSubmenu:
        [ESMenuBuilder applicationMenuNamed:appName items:@[
            [ESMenuBuilder itemWithTitle:@"Settings…" action:@selector(showSettingsWindow:) keyEquivalent:@","],
        ]]
                   toMainMenu:mainMenu];

    // ── File menu ──
    // ⇧⌘B / ⇧⌘R match the MCP app's File menu (Shift keeps them clear of ⌘B,
    // which is Bold in the field editor). Close Window is the standard
    // -performClose:, replacing the storyboard's non-standard close: wiring.
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *backUpItem = [fileMenu addItemWithTitle:@"Back Up…"
                                                 action:@selector(backUpDatabase:) keyEquivalent:@"b"];
    backUpItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    backUpItem.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.down"
                                 accessibilityDescription:@"Back Up"];
    NSMenuItem *restoreItem = [fileMenu addItemWithTitle:@"Restore…"
                                                  action:@selector(restoreDatabase:) keyEquivalent:@"r"];
    restoreItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    restoreItem.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.up"
                                  accessibilityDescription:@"Restore"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *closeItem = [fileMenu addItemWithTitle:@"Close Window"
                                                action:@selector(performClose:) keyEquivalent:@"w"];
    closeItem.image = [NSImage imageWithSystemSymbolName:@"xmark"
                              accessibilityDescription:@"Close Window"];
    [ESMenuBuilder addSubmenu:fileMenu toMainMenu:mainMenu];

    // ── Edit menu ──
    [ESMenuBuilder addSubmenu:[ESMenuBuilder editMenu] toMainMenu:mainMenu];

    // ── View menu ──
    // Standard window-chrome commands; all first-responder actions, so they
    // disable themselves when no window is key. The MCP app has no windows
    // with toolbars or a full-screen mode, so this menu is the Server's alone.
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *toolbarItem = [viewMenu addItemWithTitle:@"Show Toolbar"
                                                  action:@selector(toggleToolbarShown:) keyEquivalent:@"t"];
    toolbarItem.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [viewMenu addItemWithTitle:@"Customize Toolbar…"
                        action:@selector(runToolbarCustomizationPalette:) keyEquivalent:@""];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *fullScreenItem = [viewMenu addItemWithTitle:@"Enter Full Screen"
                                                     action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fullScreenItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    [ESMenuBuilder addSubmenu:viewMenu toMainMenu:mainMenu];

    // ── Window menu ──
    // Show Dashboard / Show Archive Scope are the main-menu equivalents of the
    // status item's entries; the builder appends the standard tail.
    NSMenuItem *dashboardItem = [ESMenuBuilder itemWithTitle:@"Show Dashboard"
                                                     action:@selector(showDashboard:) keyEquivalent:@""];
    dashboardItem.image = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                                   accessibilityDescription:@"Show Dashboard"];
    NSMenuItem *scopeItem = [ESMenuBuilder itemWithTitle:@"Show Archive Scope"
                                                 action:@selector(showMemoryScope:) keyEquivalent:@""];
    scopeItem.image = [NSImage imageWithSystemSymbolName:@"point.3.connected.trianglepath.dotted"
                               accessibilityDescription:@"Show Archive Scope"];
    [ESMenuBuilder addSubmenu:[ESMenuBuilder windowMenuWithLeadingItems:@[dashboardItem, scopeItem]]
                   toMainMenu:mainMenu];

    // ── Help menu ──
    // -showHelp: opens the app's registered help book; registering the menu as
    // NSApp.helpMenu is what makes macOS append its standard help-search field.
    // The app-help item goes first per macOS convention, extras below it.
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    [helpMenu addItemWithTitle:[NSString stringWithFormat:@"%@ Help", appName]
                        action:@selector(showHelp:) keyEquivalent:@"?"];
    [helpMenu addItem:[NSMenuItem separatorItem]];
    [helpMenu addItemWithTitle:@"Connect ES Archive…"
                        action:@selector(showConnections:) keyEquivalent:@""].target = self;
    NSApp.helpMenu = helpMenu;
    [ESMenuBuilder addSubmenu:helpMenu toMainMenu:mainMenu];

    NSApp.mainMenu = mainMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {

    // 0. Ignore SIGPIPE — GCDWebServer writes to sockets that may be closed
    //    by the remote end (e.g. MCP client probe connections). Without this,
    //    the kernel kills our process with signal 13 on any broken pipe.
    signal(SIGPIPE, SIG_IGN);

    // 0a. Install the menu-bar status item. Always visible — in Dock mode it's
    //     a convenience; in Accessory mode it's the only UI anchor.
    self.menuBarController = [[ESMenuBarController alloc] init];


    // 0b. Respect "show main window at launch". The storyboard used to open the
    //     System Pulse window unconditionally and this ordered it back out — but
    //     it matched on the class name "ViewController", which the controller was
    //     renamed away from, so the branch never fired and the preference did
    //     nothing. Nothing opens the window on its own now, so honoring the flag
    //     is simply a matter of not showing it. Closing it never quits the app:
    //     applicationShouldTerminateAfterLastWindowClosed: returns NO because the
    //     menu-bar item is the real anchor.
    if ([ESAppConfig showMainWindowAtLaunch]) {
        [self.pulseWindowController showWindow:nil];
    }

    // 1. Initialize Core Data stack
    ESLog(@"ES Archive: initializing Core Data stack...");
    ESCoreDataStack *stack = [ESCoreDataStack shared];

    // 1a. One-time migration: drop legacy auto-extracted tags. The May 2026
    //     redesign moved tags from "lexical extraction" to "curated
    //     authored objects" — every existing tag was auto-created and
    //     carries no curatorial signal. Idempotent.
    [ESTagMigration runIfNeededWithContext:stack.viewContext];

    // 1a-bis. Tag housekeeping: prune expired tags and sweep orphans left by
    //     earlier sessions. Nothing deletes a CDTag when it loses its last
    //     memory, so they accumulate; this runs at rest, where "no memories"
    //     is settled rather than a transient mid-edit state. See ESTagJanitor.
    [ESTagJanitor runStartupSweepWithContext:stack.viewContext];

    // 1b. Automatic deduplication. CloudKit can materialize the same logical
    //     row twice (import replay, cross-device races) for every syncable
    //     entity; the deduplicator installs a live detector and sweeps the
    //     whole archive — memories, links, comments, references, revisions,
    //     tags — collapsing twins and re-asserting the vector invariant.
    //     Idempotent; safe to start once here (the durable HTTP host).
    [[ESDeduplicator shared] start];

    // 2. Warm the vector cache (also preloads NaturalLanguage models for
    //    the user's primary preferred language + English fallback).
    ESLog(@"ES Archive: warming vector cache...");
    [[ESVectorEngine shared] warmCache];

    // 3b. Backfill any memories missing a vector
    [[ESVectorEngine shared] backfillMissingVectorsWithCompletion:^(NSUInteger count) {
        if (count > 0) {
            ESLog(@"ES Archive: backfilled %lu orphaned memories", (unsigned long)count);
        }
    }];

    // 4. Start MCP server. Default port 59123 (IANA dynamic range, avoids AirPlay
    //    Receiver on 5000) — the bridge (ES-Memory-Bridge.mcpb) hardcodes this URL.
    //    Per-port author bindings and per-port JWT mode are configured in the
    //    Settings window's Ports pane (ESPortConfigController), while the persona
    //    roster lives in the Personas pane (ESAuthorConfigController); both flow
    //    through ESServerConfig. The Claude-bridge injection keeps this a single
    //    Claude listener on 59123 until the user adds ports. (customPorts below is
    //    a legacy seed hint; -start: now sources ports from the table.)
    NSError *serverError = nil;
    MCPServer *mcpServer = MCPServer.sharedInstance;
    mcpServer.customPorts = @[ @([ESServerConfig effectivePort]) ];
    BOOL started = [mcpServer start:&serverError];
    if (started) {
        NSNumber *port = [[MCPServer sharedInstance] boundPortNumber];
        NSString *mode = [ESServerConfig requireAccessHeader] ? @"JWT Required" : @"Default";
        ESLog(@"ES Archive: MCP server running on localhost:%@ — mode: %@", port, mode);
    } else {
        NSLog(@"ES Archive: MCP server failed to start: %@", serverError);
    }

    // Local UNIX-domain-socket transport for the same engine — a port-free,
    // MAS-safe way for local clients to reach this one shared process. The
    // handler wraps MCPServer's dispatch result into a JSON-RPC envelope.
    NSError *udsError = nil;
    BOOL udsOK = [[MCPUnixSocketServer sharedInstance] startWithRequestHandler:^NSDictionary *(NSDictionary *rpc, NSString *author, BOOL (^isClientConnected)(void)) {
        // Cooperative shedding: skip work whose client already disconnected. See
        // design-decisions/uds-adaptation-from-template.md.
        if (isClientConnected && !isClientConnected()) {
            ESLog(@"ES Archive: shedding request for departed client");
            return nil;
        }
        id rpcId = rpc[@"id"];
        NSError *dispatchErr = nil;
        // Scope to the connection's persona (nil → default author).
        NSDictionary *result = [[MCPServer sharedInstance] dispatchJSONRPC:rpc
                                                                    scope:[ESRequestScope scopeWithAuthor:author]
                                                                    error:&dispatchErr];
        if (rpcId == nil) return nil;   // notification: no response
        if (dispatchErr) {
            return @{@"jsonrpc":@"2.0", @"id":rpcId,
                     @"error":@{@"code":@(dispatchErr.code ? : -32603),
                                @"message":dispatchErr.localizedDescription ? : @"Internal error"}};
        }
        return @{@"jsonrpc":@"2.0", @"id":rpcId, @"result":result ? : @{}};
    } error:&udsError];
    if (udsOK) {
        ESLog(@"ES Archive: engine socket at %@", MCPUnixSocketServer.sharedInstance.socketPath);
    } else {
        NSLog(@"ES Archive: engine socket failed to start: %@", udsError);
    }
}


#pragma mark - Application delegates

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    [[MCPUnixSocketServer sharedInstance] stop];
    [[MCPServer sharedInstance] stop];
    [[ESCoreDataStack shared] saveContext];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

/// Closing the dashboard never quits the app — the menu-bar status item
/// is always installed and is the real anchor for continued operation
/// (server, backup, settings). Quit via ⌘Q or the menu-bar's Quit item.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    NSManagedObjectContext *context = [ESCoreDataStack shared].viewContext;

    if (![context commitEditing]) {
        NSLog(@"%@:%@ unable to commit editing to terminate", [self class], NSStringFromSelector(_cmd));
        return NSTerminateCancel;
    }

    if (!context.hasChanges) {
        return NSTerminateNow;
    }

    NSError *error = nil;
    if (![context save:&error]) {
        BOOL result = [sender presentError:error];
        if (result) {
            return NSTerminateCancel;
        }

        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Could not save changes while quitting. Quit anyway?", nil)];
        [alert setInformativeText:NSLocalizedString(@"Quitting now will lose any changes you have made since the last successful save", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Quit anyway", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

        NSInteger answer = [alert runModal];
        if (answer == NSAlertSecondButtonReturn) {
            return NSTerminateCancel;
        }
    }

    return NSTerminateNow;
}

#pragma mark - Window Menu

- (IBAction)showMemoryScope:(id)sender {
    [[ESMemoryScopeWindowController shared] showWindow:sender];
}

#pragma mark - Help Menu

/// The Connect window, now reachable from both apps. It was MCP-only until now;
/// the class was always compiled into this target (it is in neither exclusion
/// list), so only the menu item was missing.
///
/// NEEDS PER-APP CUSTOMISATION before this is fit for users. Two of the window's
/// three sections are stdio-specific, because both build their configuration
/// from +[ESConnectHelper serverExecutablePath], which returns
/// NSBundle.mainBundle.executablePath — the RUNNING binary:
///
///   * "Connect to Claude Desktop" writes a connector .mcpb pointing at this
///     Server binary. The Server target excludes the Stdio sources, so Claude
///     would spawn it with pipes and get a process that never speaks JSON-RPC.
///   * The LM Studio config JSON embeds the same path, with the same result.
///   * "Install Claude Skills" is correct as-is — the skill suite is bundled
///     with both targets.
///
/// The Server's own connection story is the HTTP bridge on localhost plus the
/// ports / personas / JWT settings, so that is what its version of this window
/// should describe.
- (IBAction)showConnections:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [ESHTTPConnectController show];
}

#pragma mark - Settings Menu

/// Wired to the Settings menu item (⌘,) and reached from the menu-bar status
/// item via ESMenuBarController. The window was a storyboard scene
/// ("SettingsWindow") whose tab controller pulled in the UI Settings scene;
/// both are gone — ESSettingsTabViewController now builds all three panes in
/// code, so this just wraps it in a window.
- (IBAction)showSettingsWindow:(id)sender {
    // If we already have a controller and its window is visible, just bring it forward.
    if (self.settingsWindowController && self.settingsWindowController.window.isVisible) {
        [self.settingsWindowController.window makeKeyAndOrderFront:nil];
        return;
    }

    if (!self.settingsWindowController) {
        ESSettingsTabViewController *tabs = [[ESSettingsTabViewController alloc] init];
        NSWindow *window = [NSWindow windowWithContentViewController:tabs];
        window.title = @"Settings";
        window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        // The preference toolbar style is what gives the tab controller's toolbar
        // the centered, label-under-icon look of a settings window. The storyboard
        // declared it on the window; it has to be set explicitly here.
        window.toolbarStyle = NSWindowToolbarStylePreference;
        window.restorable = NO;
        window.releasedWhenClosed = NO;
        [window center];
        self.settingsWindowController = [[NSWindowController alloc] initWithWindow:window];
        // So -windowWillClose: can drop our strong reference.
        window.delegate = self;
    }

    [self.settingsWindowController showWindow:self];

    // Bring the app forward — in Accessory (menu-bar-only) mode windows open
    // behind the frontmost app unless we activate.
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)showDashboard:(id)sender {
    // Bring the app forward in case we're in Accessory (menu-bar-only) mode
    // where windows don't get activated by default.
    [NSApp activateIgnoringOtherApps:YES];
    [self.pulseWindowController showWindow:sender];
}

/// The System Pulse window — the app's dashboard, and the last thing
/// Main.storyboard owned. It was the storyboard's initial scene, so
/// NSApplicationMain opened it; nothing opens it implicitly now, which is what
/// finally makes "show main window at launch" mean something.
///
/// ESSystemPulseViewController already overrode -loadView and built its whole UI
/// in code, so the storyboard scene contributed nothing but an unused 480×270
/// placeholder view. Only the window itself had to be ported: title, style, and
/// the top-left screen placement its initialPositionMask asked for. Created
/// lazily and cached, so closing and reopening keeps one window (the controller
/// holds it; releasedWhenClosed would dangle it).
- (NSWindowController *)pulseWindowController {
    if (_pulseWindowController) return _pulseWindowController;

    ESSystemPulseViewController *vc = [[ESSystemPulseViewController alloc] init];
    NSWindow *window = [NSWindow windowWithContentViewController:vc];
    window.title = @"System Pulse";
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    // The pane is a fixed-size readout — full screen has nothing to give it.
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
    window.releasedWhenClosed = NO;

    // leftStrut + topStrut in the storyboard: pinned to the top-left of the
    // screen's visible area rather than cascaded.
    NSScreen *screen = NSScreen.mainScreen;
    if (screen) {
        NSRect visible = screen.visibleFrame;
        [window setFrameOrigin:NSMakePoint(NSMinX(visible),
                                           NSMaxY(visible) - NSHeight(window.frame))];
    }

    _pulseWindowController = [[NSWindowController alloc] initWithWindow:window];
    return _pulseWindowController;
}


#pragma mark - NSWindowDelegate

/// Called when the settings window is closed – release our strong reference.
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settingsWindowController.window) {
        self.settingsWindowController = nil;
    }
}

#pragma mark - File Menu

- (IBAction)backUpDatabase:(id)sender {
    [ESBackupCommands presentBackupPanel];
}

- (IBAction)restoreDatabase:(id)sender {
    [ESBackupCommands presentRestorePanel];
}


#pragma mark - Tools Menu

- (IBAction)reindexVectors:(id)sender {
    [[ESVectorEngine shared] recomputeAllVectorsWithCompletion:^(BOOL success, NSUInteger count, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *done = [[NSAlert alloc] init];
            if (success) {
                done.messageText = @"Reindex complete";
                done.informativeText = [NSString stringWithFormat:@"%lu vectors recomputed.",
                                        (unsigned long)count];
            } else {
                done.messageText = @"Reindex failed";
                done.informativeText = error.localizedDescription ?: @"Unknown error.";
                done.alertStyle = NSAlertStyleWarning;
            }
            [done addButtonWithTitle:@"OK"];
            [done runModal];
        });
    }];
}

- (IBAction)toggleActivityLog:(id)sender {}

@end
