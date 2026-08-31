//
//  ESMenuBuilder.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMenuBuilder.h"

/// -undo: / -redo: are first-responder actions with no public declaration —
/// AppKit's field editor implements them, and the menu items reach it through
/// the responder chain. Declaring them here just keeps @selector() from warning.
@interface NSObject (ESUndoMenuActions)
- (void)undo:(id)sender;
- (void)redo:(id)sender;
@end

@implementation ESMenuBuilder

+ (NSMenuItem *)itemWithTitle:(NSString *)title
                       action:(nullable SEL)action
                keyEquivalent:(NSString *)keyEquivalent {
    return [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent];
}

+ (void)addSubmenu:(NSMenu *)submenu toMainMenu:(NSMenu *)mainMenu {
    NSMenuItem *item = [NSMenuItem new];
    item.submenu = submenu;
    [mainMenu addItem:item];
}

+ (NSMenu *)applicationMenuNamed:(NSString *)appName
                           items:(nullable NSArray<NSMenuItem *> *)items {
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    for (NSMenuItem *item in items) {
        [appMenu addItem:item];
    }
    if (items.count > 0) {
        [appMenu addItem:[NSMenuItem separatorItem]];
    }

    NSMenu *servicesMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Services" action:NULL keyEquivalent:@""].submenu = servicesMenu;
    NSApp.servicesMenu = servicesMenu;
    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                       action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                       action:@selector(terminate:) keyEquivalent:@"q"];

    return appMenu;
}

+ (NSMenu *)editMenu {
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagShift | NSEventModifierFlagCommand;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    return editMenu;
}

+ (NSMenu *)windowMenuWithLeadingItems:(nullable NSArray<NSMenuItem *> *)items {
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

    for (NSMenuItem *item in items) {
        [windowMenu addItem:item];
    }
    if (items.count > 0) {
        [windowMenu addItem:[NSMenuItem separatorItem]];
    }

    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

    NSApp.windowsMenu = windowMenu;
    return windowMenu;
}

@end
