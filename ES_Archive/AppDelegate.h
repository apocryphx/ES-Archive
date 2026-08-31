//
//  AppDelegate.h
//  ES Archive
//
//  Created by Kolja Wawrowsky on 3/2/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>

// — File menu —
- (IBAction)backUpDatabase:(id)sender;
- (IBAction)restoreDatabase:(id)sender;

// — Tools menu —
- (IBAction)reindexVectors:(id)sender;
- (IBAction)toggleActivityLog:(id)sender;

// — Window menu —
- (IBAction)showMemoryScope:(id)sender;

// — Settings menu —
- (IBAction)showSettingsWindow:(id)sender;
- (IBAction)showDashboard:(id)sender;

// — Help menu —
- (IBAction)showConnections:(id)sender;

@end

