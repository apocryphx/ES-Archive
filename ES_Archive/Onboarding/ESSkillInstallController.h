//
//  ESSkillInstallController.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The "Install Claude Skills" window: one row per bundled skill with a Read
/// button (the SKILL.md in a sheet) and an Install button that turns gray with a
/// green checkmark once the skill has been handed to Claude Desktop.
///
/// Installing packs the skill as a .skill (a zip holding `<name>/SKILL.md`,
/// built in-process by ESZip), writes it to the app-owned Application Support
/// folder and opens it in Claude Desktop by bundle identifier — the equivalent
/// of a double-click, minus Launch Services deciding which app gets the file.
/// Claude Desktop shows its own confirmation per skill and replaces an existing
/// copy of the same name.
///
/// The skills come from Resources/Skills/<name>/SKILL.md, staged from
/// skills/claude by the "Bundle Claude skills" build phase, so an app build
/// always carries the skill text matching its tool surface. Target-neutral:
/// both apps bundle and offer the same suite.
@interface ESSkillInstallController : NSWindowController

+ (instancetype)shared;

/// Show the window and bring the app forward.
+ (void)show;

@end

NS_ASSUME_NONNULL_END
