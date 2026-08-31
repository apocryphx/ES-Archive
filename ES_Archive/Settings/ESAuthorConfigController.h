//
//  ESAuthorConfigController.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Settings pane for the persona (author) list itself: create a persona,
//  delete one (with all of its records), rename, and merge one into another.
//  Port bindings live on the separate Ports pane (ESPortConfigController);
//  this pane never touches which port serves which persona except to keep
//  the map consistent after a delete/rename/merge. Built entirely in code so
//  it needs no storyboard scene; ESSettingsTabViewController appends it as a
//  tab at runtime.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESAuthorConfigController : NSViewController

/// Every persona the app knows about: distinct authors in the archive plus
/// explicitly declared personas that have no records yet, sorted
/// alphabetically. The Ports pane uses this to offer canonical spellings.
+ (NSArray<NSString *> *)allKnownAuthors;

@end

NS_ASSUME_NONNULL_END
