//
//  ESPortConfigController.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Settings pane for the port → persona bindings (plus per-port JWT). Each row
//  binds a listening port to a canonical persona author chosen from a popup of
//  the archive's known personas, so a canonical spelling is picked, never
//  retyped (the Freya/Frey drift this whole design eliminates). Creating,
//  deleting, renaming, and merging personas happens on the Personas pane
//  (ESAuthorConfigController). Built entirely in code so it needs no
//  storyboard scene; ESSettingsTabViewController appends it as a tab at
//  runtime.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESPortConfigController : NSViewController
@end

NS_ASSUME_NONNULL_END
