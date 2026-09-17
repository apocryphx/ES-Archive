//
//  ESStdioAppDelegate.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioAppDelegate.h"
#import "ESEngine.h"
#import "ESVectorEngine.h"
#import "ESCoreDataStack.h"
#import "ESTagJanitor.h"
#import "ESStdioStatusItemController.h"
#import "MCPStdioServer.h"
#import "ESStdioConnectController.h"
#import "ESConnectHelper.h"
#import "ESAppConfig.h"
#import "ESStdioSettingsController.h"
#import "ESStdioPersonaController.h"
#import "ESBackupCommands.h"
#import "ESMenuBuilder.h"
#import "ESMemoryScopeWindowController.h"

@interface ESStdioAppDelegate ()
@property (strong) ESStdioStatusItemController *statusItemController;
/// Set once this process has taken on the host's GUI and housekeeping — at launch
/// or after a mid-session re-election. Never runs twice.
@property (nonatomic) BOOL hostRoleActive;
/// When -applicationDidFinishLaunching ran. A re-election that promotes this
/// process within kESStartupWindow of it is still part of startup (Claude
/// Desktop's probe handoff), not a mid-session event. See -activateHostRoleAtLaunch:.
@property (strong) NSDate *launchDate;
- (void)installUserMainMenu;
- (void)showConnections:(id)sender;
- (void)showSettings:(id)sender;
@end

/// A promotion by re-election this soon after launch counts as startup.
static const NSTimeInterval kESStartupWindow = 30.0;
/// How long an AI-spawned host waits before greeting. Claude Desktop's probe
/// instance is SIGKILLed about a second after it starts; a host that dies inside
/// this delay never flashes a window, and the one that survives it is the real host.
static const NSTimeInterval kESGreetDelay = 2.0;

@implementation ESStdioAppDelegate

/// Apply the host's UI mode from ESAppConfig — the same preference the Server app
/// and the settings pane use. Dock ⇒ Regular (Dock icon + main menu); Menu-bar ⇒
/// Accessory (status item only, no main menu). The two surfaces are mutually
/// exclusive — see -applicationDidFinishLaunching. Applied once at launch — a mode
/// change made in Settings takes effect on the next session (see
/// ESStdioSettingsController).
- (void)applyHostUIMode {
    [NSApp setActivationPolicy:([ESAppConfig activationMode] == ESActivationModeMenuBar)
        ? NSApplicationActivationPolicyAccessory
        : NSApplicationActivationPolicyRegular];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    fprintf(stderr, "[es-archive-mcp] applicationDidFinishLaunching\n");
    self.launchDate = [NSDate date];

    // Engine first — it runs the socket election, which decides our role.
    [[ESEngine shared] start];

    // A relay whose host goes away does not die with it: ESEngine re-elects
    // (reconnects to the next host, or binds the socket and loads the engine
    // itself). If it comes out of that as the host, it takes on the host's GUI and
    // housekeeping here, mid-session. See design-decisions/mid-session-reelection.md.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(engineDidBecomeHost:)
                                               name:ESEngineDidBecomeHostNotification
                                             object:nil];

    // host ⟺ GUI. The instance that runs the engine in-process (won the election,
    // or is standalone with no peer) is the one place FRCs and
    // ESToolExecutedNotification fire against live data — so it, and only it, raises
    // the GUI. Every relay stays a headless client of that host. This is the stdio
    // analogue of the HTTP server: first access starts the server (with GUI), the
    // rest connect. See design-decisions/uds-adaptation-from-template.md.
    BOOL servesLocally = [ESEngine shared].servesLocally;

    if (servesLocally) {
        [self activateHostRoleAtLaunch:YES];
    } else if (!self.launchedByAI) {
        // A user launched us, but a host is already running and there is no stdin
        // client to serve: nothing to host, nothing to relay, and the running host
        // owns the one GUI. Exit rather than linger as an invisible process.
        fprintf(stderr, "[es-archive-mcp] a host is already running — nothing to do, exiting\n");
        [NSApp terminate:nil];
        return;
    } else {
        fprintf(stderr, "[es-archive-mcp] relay — headless client of the running host\n");
    }

    // Run the stdin read-loop only when a client is actually on the pipe. A user
    // launch has /dev/null on stdin; its loop would instant-EOF and drain-terminate.
    if (self.launchedByAI) {
        [[MCPStdioServer shared] start];
    }
}

// Posted on main by ESEngine after a re-election left this process hosting.
- (void)engineDidBecomeHost:(NSNotification *)note {
    [self activateHostRoleAtLaunch:NO];
}

/// Everything a host does beyond serving requests: the one GUI surface, and the
/// write-side housekeeping that must run in exactly one process. `atLaunch` is YES
/// from -applicationDidFinishLaunching and NO when a relay was promoted by a
/// mid-session re-election — the latter must not take focus away from whatever
/// the user is doing.
- (void)activateHostRoleAtLaunch:(BOOL)atLaunch {
    if (self.hostRoleActive) return;
    self.hostRoleActive = YES;

    fprintf(stderr, "[es-archive-mcp] serving locally — raising the GUI (%s)%s\n",
            [ESAppConfig activationMode] == ESActivationModeMenuBar ? "Minimal" : "Full",
            atLaunch ? "" : " after re-election");
    // Mutually exclusive surfaces, keyed to the persisted UI mode: Full drives
    // everything from the main menu (a Dock app), Minimal from the menu-bar status
    // item. Both fire the same delegate commands (Back Up / Restore / Archive Scope)
    // through the responder chain, so exactly one surface exists at a time. Safe
    // here because we hold the engine in-process — an FRC-backed Archive Scope on a
    // relay would bind to an empty context.
    if ([ESAppConfig activationMode] == ESActivationModeMenuBar) {
        self.statusItemController = [[ESStdioStatusItemController alloc] init];
    } else {
        [self installUserMainMenu];
    }
    // Full (Dock icon) vs Minimal (menu-bar only) is the user's persisted
    // choice — no longer tied to how we were launched.
    [self applyHostUIMode];
    // In Full mode the host behaves like any app on launch: it comes to the
    // foreground and greets with onboarding, whether the USER opened it or
    // Claude spawned it — a user expects the app to show itself when it starts,
    // and the host is the app's one live GUI (host ⟺ GUI). Minimal (menu-bar)
    // mode is the deliberate "stay a quiet background service" opt-out — it's
    // Accessory, so it neither shows a Dock icon nor takes focus. Foregrounding
    // a Claude-spawned host does NOT fight Claude Desktop for focus: Claude
    // spawns the MCP server as part of its own startup, before its window is
    // activated, so the host comes up within the launch sequence rather than
    // interrupting a Claude session already in front. A promotion mid-session is
    // different — the user is in the middle of something — so it gets the Dock
    // icon and menu but neither onboarding nor focus.
    //
    // "Startup" is wider than -applicationDidFinishLaunching, though. Claude
    // Desktop spawns us three times at launch; its probe instance usually wins
    // the bind, greets, and is SIGTERM+SIGKILLed about a second later — the
    // linger in MCPStdioServer cannot outlive a SIGKILL. The real instance then
    // hosts by re-election, tens of milliseconds after its own launch. So a
    // promotion inside kESStartupWindow of this process's launch is startup too.
    // And an AI-spawned host greets only after kESGreetDelay, and only if its
    // own stdio session is still open by then. Desktop closes the probe's stdin
    // about a second in (the SIGKILL follows seconds later, at Desktop's pace —
    // not something to time against), so the probe's timer finds sessionEnded
    // and stands down; the survivor with a live session is the real host. A
    // hand-launched app has no probe to wait out and greets at once.
    BOOL startup = atLaunch || -[self.launchDate timeIntervalSinceNow] < kESStartupWindow;
    if (startup && [ESAppConfig activationMode] != ESActivationModeMenuBar) {
        NSTimeInterval delay = self.launchedByAI ? kESGreetDelay : 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.launchedByAI && [MCPStdioServer shared].sessionEnded) {
                fprintf(stderr, "[es-archive-mcp] not greeting — own stdio session already ended\n");
                return;
            }
            // Still alive ⇒ still the host: a host never demotes.
            fprintf(stderr, "[es-archive-mcp] greeting — onboarding and focus%s\n",
                    atLaunch ? "" : " (host by re-election during startup)");
            [ESStdioConnectController showAtStartupIfEnabled];
            [NSApp activate];
        });
    }

    // Tag housekeeping — host only, like the vector backfill below: this
    // writes, and writes funnel through the one instance holding the engine.
    [ESTagJanitor runStartupSweepWithContext:[ESCoreDataStack shared].viewContext];

    // Backfill vectors for embeddable memories that lack one — the same pass
    // the HTTP Server app runs on launch (AppDelegate.m). Memories synced in
    // from another device arrive without a vector, and only the engine host
    // can encode them; whichever instance ends up hosting (user-launched,
    // Claude-spawned, or promoted by re-election) does it here, so it can't
    // silently rot. Additive, idempotent, self-limiting: a clean archive is a
    // no-op (completion 0), the first host clears the deficit, and it runs once
    // per host — never per request. Writes funnel through this one host, so the
    // single-writer invariant holds.
    [[ESVectorEngine shared] backfillMissingVectorsWithCompletion:^(NSUInteger count) {
        if (count > 0) {
            fprintf(stderr, "[es-archive-mcp] backfilled %lu memories missing a vector\n",
                    (unsigned long)count);
        }
    }];
}

/// The MCP target bypasses NSApplicationMain, so no menu comes from a storyboard.
/// Full mode builds the standard menu bar here in code: App (About · Settings ⌘, ·
/// Configure · Services · Hide · Quit ⌘Q), File (Back Up… ⇧⌘B · Restore… ⇧⌘R ·
/// Close Window ⌘W), Edit
/// (so Cut/Copy/Paste/Select-All work in the Onboarding & Settings text fields), and
/// Window (Show Archive Scope · Minimize · Zoom · Bring All to Front — macOS injects
/// the rest) and Help (ES Archive MCP Help ⌘? · Connect ES Archive…).
/// Most items use the nil target so AppKit routes them through the
/// responder chain; Settings/Configure target the delegate, and Back Up / Restore /
/// Show Archive Scope resolve to the delegate's command handlers via First Responder
/// (the Minimal-mode status item reaches the same handlers by targeting the delegate
/// directly).
- (void)installUserMainMenu {
    NSString *appName = NSRunningApplication.currentApplication.localizedName ?: @"ES Archive";
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // ── Application menu ──
    // Standard macOS location: App menu ▸ Settings… (⌘,). Same panes the status
    // item opens, so these two target the delegate directly.
    NSMenuItem *settingsItem = [ESMenuBuilder itemWithTitle:@"Settings…"
                                                    action:@selector(showSettings:) keyEquivalent:@","];
    settingsItem.target = self;
    NSMenuItem *personasItem = [ESMenuBuilder itemWithTitle:@"Manage Personas…"
                                                    action:@selector(showPersonas:) keyEquivalent:@""];
    personasItem.target = self;
    [ESMenuBuilder addSubmenu:[ESMenuBuilder applicationMenuNamed:appName
                                                            items:@[settingsItem, personasItem]]
                   toMainMenu:mainMenu];

    // ── File menu ──
    // Back Up… / Restore… carry ⇧⌘B / ⇧⌘R and use the nil target: AppKit routes them
    // through the responder chain to the delegate's -backUp: / -restore:, the very
    // handlers the Minimal-mode status item reaches. (Shift keeps them clear of ⌘B,
    // which is Bold in the field editor.) Close Window is the standard First-Responder
    // -performClose: (⌘W), so it auto-disables when no window is key. The SF Symbols
    // match the Server target's File menu.
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *backUpItem = [fileMenu addItemWithTitle:@"Back Up…"
                                                 action:@selector(backUp:) keyEquivalent:@"b"];
    backUpItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    backUpItem.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.down"
                                 accessibilityDescription:@"Back Up"];
    NSMenuItem *restoreItem = [fileMenu addItemWithTitle:@"Restore…"
                                                  action:@selector(restore:) keyEquivalent:@"r"];
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
    // Makes Cut/Copy/Paste/Select-All work in the Onboarding and Settings fields.
    [ESMenuBuilder addSubmenu:[ESMenuBuilder editMenu] toMainMenu:mainMenu];

    // ── Window menu ──
    // Show Archive Scope is the Full-mode equivalent of the status item's entry —
    // nil target, routed to the delegate; the builder appends the standard tail.
    [ESMenuBuilder addSubmenu:
        [ESMenuBuilder windowMenuWithLeadingItems:@[
            [ESMenuBuilder itemWithTitle:@"Show Archive Scope"
                                  action:@selector(showMemoryScope:) keyEquivalent:@""],
        ]]
                   toMainMenu:mainMenu];

    // ── Help menu ──
    // Onboarding lives here by macOS convention (welcome/setup content under
    // Help): the Connect window with the Claude Desktop connector, the skill
    // install list, and the LM Studio config. Registered as NSApp.helpMenu so
    // macOS appends its standard help-search field.
    //
    // The app-help item goes first, per macOS convention and matching the Server
    // target. -showHelp: does nothing in either app until a help book is
    // registered (CFBundleHelpBookFolder / CFBundleHelpBookName); the item is
    // here so both menus have the same shape when that lands.
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

/// The Connect window — Claude Desktop connector, the per-skill install list, and
/// the LM Studio config. Reached from Help ▸ Connect ES Archive… and from the
/// Minimal-mode status item. A File ▸ Install Claude Skills… item used to open
/// this same window too; it dates from when installing skills was its own
/// open-panel command, and was removed once the Connect window absorbed the job.
- (void)showConnections:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [ESStdioConnectController show];
}

- (void)showSettings:(id)sender {
    [ESStdioSettingsController showSettings];   // activates the app itself
}

- (void)showPersonas:(id)sender {
    [ESStdioPersonaController showPersonas];    // activates the app itself
}

#pragma mark - Commands (shared by the main menu and the status item)

// Reached through the responder chain (nil target) from whichever surface is live —
// the Full-mode main menu or the Minimal-mode status item. Accessory apps open behind
// the frontmost app unless activated first, so activate before presenting a panel.

- (void)showMemoryScope:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [[ESMemoryScopeWindowController shared] showWindow:sender];
}

/// Mirrors -[AppDelegate backUpDatabase:] in the Server target so both hosts
/// produce identical archives.
- (void)backUp:(id)sender {
    [ESBackupCommands presentBackupPanel];
}

/// Mirrors -[AppDelegate restoreDatabase:] in the Server target.
- (void)restore:(id)sender {
    [ESBackupCommands presentRestorePanel];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    // Belt and braces — the EOF/SIGTERM drain already saved. Idempotent.
    [[ESEngine shared] flushAndSave];
    fprintf(stderr, "[es-archive-mcp] applicationWillTerminate\n");
}

@end
