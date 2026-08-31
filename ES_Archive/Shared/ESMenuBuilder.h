//
//  ESMenuBuilder.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// The parts of a macOS menu bar that carry no app-specific content, shared by
/// both apps' -installMainMenu.
///
/// Once the Server app's menu moved off Main.storyboard the two implementations
/// were 77% identical, and every identical line was boilerplate: the standard
/// App menu wrapper, the whole Edit menu, and the Window menu tail. What differs
/// stays with each app — the Server's View menu and Show Dashboard, the MCP
/// app's Manage Personas and Connect items — and is passed in, so the shared
/// code never has to know which app it is building for.
@interface ESMenuBuilder : NSObject

/// About · separator · `items` · separator · Services · Hide/Hide Others/Show
/// All · Quit. Registers the Services submenu as NSApp.servicesMenu.
+ (NSMenu *)applicationMenuNamed:(NSString *)appName
                           items:(nullable NSArray<NSMenuItem *> *)items;

/// Undo/Redo · Cut/Copy/Paste/Delete/Select All — all first-responder actions,
/// which is what makes text fields in the Settings and Onboarding windows
/// editable.
+ (NSMenu *)editMenu;

/// `items` · separator · Minimize · Zoom · Bring All to Front. Registers the
/// result as NSApp.windowsMenu, which is what makes macOS inject Fill / Center /
/// Move & Resize and the window list.
+ (NSMenu *)windowMenuWithLeadingItems:(nullable NSArray<NSMenuItem *> *)items;

/// A standalone item for the `items` arrays above. Command is the default
/// modifier, matching -addItemWithTitle:action:keyEquivalent:.
+ (NSMenuItem *)itemWithTitle:(NSString *)title
                       action:(nullable SEL)action
                keyEquivalent:(NSString *)keyEquivalent;

/// Wrap `submenu` in the top-level item a menu bar requires, and append it.
/// AppKit treats the first one added as the application menu.
+ (void)addSubmenu:(NSMenu *)submenu toMainMenu:(NSMenu *)mainMenu;

@end

NS_ASSUME_NONNULL_END
