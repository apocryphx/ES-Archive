//
//  ESStdioStatusItemController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioStatusItemController.h"
#import "ESStdioAppDelegate.h"   // Back Up / Restore / Show Archive Scope selectors
#import "ESStdioSettingsController.h"
#import "ESCoreDataStack.h"
#import "ESOnboardingWindowController.h"

@interface ESStdioStatusItemController () <NSMenuDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem   *countItem;
@end

@implementation ESStdioStatusItemController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [self statusImage];
    self.statusItem.button.image.template = YES;
    self.statusItem.button.toolTip = @"ES Archive MCP";
    self.statusItem.menu = [self buildMenu];

    return self;
}

- (void)dealloc {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    }
}

#pragma mark - Menu construction

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *header = version.length
        ? [NSString stringWithFormat:@"ES Archive MCP %@", version]
        : @"ES Archive MCP";
    NSMenuItem *headerItem = [[NSMenuItem alloc] initWithTitle:header action:nil keyEquivalent:@""];
    headerItem.enabled = NO;
    [menu addItem:headerItem];

    self.countItem = [[NSMenuItem alloc] initWithTitle:@"Entries: —" action:nil keyEquivalent:@""];
    self.countItem.enabled = NO;
    [menu addItem:self.countItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Show Archive Scope / Back Up / Restore are the app delegate's commands. The
    // Full-mode main menu reaches them via First Responder, but a background status
    // item has no key-window responder chain, so nil-target items would validate to
    // disabled — target the delegate explicitly instead, the same way the HTTP app's
    // ESMenuBarController forwards to its app delegate. The ⇧⌘B / ⇧⌘R accelerators
    // fire only while this menu is open; a menu-bar-only host has no main menu to
    // catch them globally.
    id delegate = NSApp.delegate;
    [menu addItemWithTitle:@"Show Archive Scope"
                    action:@selector(showMemoryScope:)
             keyEquivalent:@""].target = delegate;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *backUpItem = [menu addItemWithTitle:@"Back Up…"
                                             action:@selector(backUp:)
                                      keyEquivalent:@"b"];
    backUpItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    backUpItem.target = delegate;

    NSMenuItem *restoreItem = [menu addItemWithTitle:@"Restore…"
                                              action:@selector(restore:)
                                       keyEquivalent:@"r"];
    restoreItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    restoreItem.target = delegate;

    // Persona housekeeping (delete / merge) — a delegate command like the ones
    // above, so both this status item and the Full-mode main menu share it.
    [menu addItemWithTitle:@"Manage Personas…"
                    action:@selector(showPersonas:)
             keyEquivalent:@""].target = delegate;

    [menu addItem:[NSMenuItem separatorItem]];

    // Opens the Connect dialog — the connector, the per-skill install list, and
    // the LM Studio config. Same name as the Full-mode Help menu item and the
    // window title, so all three read as one surface.
    [menu addItemWithTitle:@"Connect ES Archive…"
                    action:@selector(showConfigure:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    // App settings: Dock vs Menu-bar mode, launch-at-login, show-main-window.
    // The only surface for these in Minimal mode, where there is no app menu / Dock.
    [menu addItemWithTitle:@"Settings…"
                    action:@selector(showSettings:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    // Quit lives here because in Minimal (menu-bar) mode this status item is the
    // only always-present surface — no Dock icon, no visible app main menu — so
    // without it a host cannot be shut down from the UI at all. Routed to NSApp via
    // terminate:, the same action the app menu's Quit uses in Full mode. Quitting an
    // MCP-client-spawned host just drops that client's connection, exactly as
    // quitting from the app menu already does.
    NSString *appName = NSRunningApplication.currentApplication.localizedName ?: @"ES Archive";
    NSMenuItem *quitItem = [menu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                                           action:@selector(terminate:)
                                    keyEquivalent:@"q"];
    quitItem.target = NSApp;

    return menu;
}

#pragma mark - Actions

// Back Up / Restore / Show Archive Scope are handled by the app delegate (this menu
// targets it directly; see -buildMenu), so the Full-mode main menu and this status
// item share one implementation — see ESStdioAppDelegate. Only the two item-specific
// actions below live here, since only this menu offers them.

// Accessory (LSUIElement) apps open behind the frontmost app unless activated
// first — same pattern the HTTP app's ESMenuBarController uses.
- (void)showConfigure:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [ESOnboardingWindowController show];
}

- (void)showSettings:(id)sender {
    [ESStdioSettingsController showSettings];   // activates the app itself
}

/// Refresh the live memory count each time the menu opens.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSNumber *count = ExecuteOnMainThread(^id {
        NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        // CDMemoryRevision is a CDMemory subentity — without this, every
        // revision snapshot counts as a memory and the number reads inflated.
        req.includesSubentities = NO;
        NSError *err = nil;
        NSUInteger c = [[ESCoreDataStack shared].viewContext countForFetchRequest:req error:&err];
        return err ? nil : @(c);
    });
    self.countItem.title = count.boolValue
        ? [NSString stringWithFormat:@"Entries: %lu", count.unsignedLongValue]
        : @"Entries: —";
}

- (NSImage *)statusImage {
    // Same symbol as the HTTP app's menu bar item, so both hosts read as
    // one product.
    NSImage *img = [NSImage imageWithSystemSymbolName:@"brain.head.profile"
                             accessibilityDescription:@"ES Archive MCP"];
    return img ?: [NSImage imageNamed:NSImageNameStatusAvailable];
}

@end
