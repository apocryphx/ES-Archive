//
//  ESMenuBarController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMenuBarController.h"
#import "MCPServer.h"
#import "AppDelegate.h"

static void * const kMCPServerPortContext = (void *)&kMCPServerPortContext;

@interface ESMenuBarController ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem   *headerItem;
@end

@implementation ESMenuBarController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    // The Electric Sheep emoji marks the HTTP server, distinct from the stdio
    // ES Archive MCP app's brain.head.profile icon. Using a color emoji as the
    // button title (rather than a template image) sidesteps the invisible
    // sub-pixel hairline the stroke-only logo art produced at menu-bar size,
    // and reads unmistakably as Electric Sheep. Variable length so the item
    // sizes to the glyph.
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"🐑";
    self.statusItem.button.toolTip = @"ES Archive Server";
    self.statusItem.menu = [self buildMenu];

    // KVO on boundPortNumber — NSKeyValueObservingOptionInitial fires once
    // immediately so the header label gets its first value without a manual
    // refresh.
    [[MCPServer sharedInstance] addObserver:self
                                 forKeyPath:@"boundPortNumber"
                                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                    context:kMCPServerPortContext];
    return self;
}

- (void)dealloc {
    [[MCPServer sharedInstance] removeObserver:self
                                    forKeyPath:@"boundPortNumber"
                                       context:kMCPServerPortContext];
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    }
}

#pragma mark - Menu construction

- (NSMenu *)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    // Live header — updated by -observeValueForKeyPath:.
    self.headerItem = [[NSMenuItem alloc] initWithTitle:@"ES Archive" action:nil keyEquivalent:@""];
    self.headerItem.enabled = NO;
    [menu addItem:self.headerItem];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Copy URL"
                    action:@selector(copyURL:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Show Dashboard"
                    action:@selector(showDashboard:)
             keyEquivalent:@""].target = self;

    [menu addItemWithTitle:@"Open Archive Scope"
                    action:@selector(openMemoryScope:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Reindex Vectors"
                    action:@selector(reindexVectors:)
             keyEquivalent:@""].target = self;

    [menu addItemWithTitle:@"Back Up…"
                    action:@selector(backUp:)
             keyEquivalent:@""].target = self;

    [menu addItemWithTitle:@"Restore…"
                    action:@selector(restore:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Settings…"
                    action:@selector(showSettings:)
             keyEquivalent:@","].target = self;

    [menu addItemWithTitle:@"Quit ES Archive"
                    action:@selector(quit:)
             keyEquivalent:@"q"].target = self;

    return menu;
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context == kMCPServerPortContext) {
        NSNumber *port = [MCPServer sharedInstance].boundPortNumber;
        self.headerItem.title = (port != nil)
            ? [NSString stringWithFormat:@"● Running — localhost:%@", port]
            : @"○ Stopped";
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark - Actions

- (AppDelegate *)appDelegate {
    return (AppDelegate *)NSApp.delegate;
}

- (void)copyURL:(id)sender {
    NSNumber *port = [MCPServer sharedInstance].boundPortNumber;
    if (port == nil) {
        NSBeep();
        return;
    }
    NSString *url = [NSString stringWithFormat:@"http://localhost:%@/mcp", port];
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:url forType:NSPasteboardTypeString];
}

- (IBAction)showDashboard:(id)sender {
    // Bring the app forward in case we're in Accessory (menu-bar-only) mode
    // where windows don't get activated by default.
    [self.appDelegate showDashboard:sender];

}

- (IBAction)openMemoryScope:(id)sender {
    [self.appDelegate showMemoryScope:sender];
}

- (void)backUp:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.appDelegate backUpDatabase:sender];
}

- (void)restore:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.appDelegate restoreDatabase:sender];
}

- (void)reindexVectors:(id)sender {
    [self.appDelegate reindexVectors:sender];
}

- (void)showSettings:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.appDelegate showSettingsWindow:sender];
}

- (void)quit:(id)sender {
    [NSApp terminate:sender];
}

@end
