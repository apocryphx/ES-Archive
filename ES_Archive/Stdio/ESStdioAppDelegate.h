//
//  ESStdioAppDelegate.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Cocoa/Cocoa.h>

@interface ESStdioAppDelegate : NSObject <NSApplicationDelegate>
/// YES when spawned by an AI host over stdio pipes; NO when the user launched the
/// app directly. Governs whether the stdin read-loop runs (an AI host serves a
/// pipe; a user launch does not) and whether a redundant user launch exits when a
/// host already runs — NOT the UI mode, and NOT focus-at-launch, which now follows
/// the Full/Minimal activation mode. Set by ESStdioMain before
/// -applicationDidFinishLaunching: runs.
@property (nonatomic) BOOL launchedByAI;

/// Menu commands shared by the two mutually-exclusive surfaces. The Full-mode main
/// menu reaches them via First Responder; the Minimal-mode status item targets this
/// delegate directly. Either way one implementation serves whichever surface is live.
- (void)showMemoryScope:(id)sender;
- (void)backUp:(id)sender;
- (void)restore:(id)sender;
- (void)showPersonas:(id)sender;
@end
