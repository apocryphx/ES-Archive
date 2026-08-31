//
//  ESStdioConnectController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioConnectController.h"
#import "ESConnectHelper.h"

@implementation ESStdioConnectController

/// Claude Desktop first — the one-click path, and what most users are here for —
/// then the generic stdio hosts.
- (void)addSectionsToStack:(NSStackView *)stack {
    NSTextField *claudeCopy = [self bodyLabel:
        @"Open Claude’s secure install dialog and approve ES Archive. That’s it — no configuration files to edit."];
    NSButton *connect = [NSButton buttonWithTitle:@"Connect to Claude"
                                           target:self action:@selector(connectClaude:)];
    connect.bezelStyle = NSBezelStyleRounded;
    connect.keyEquivalent = @"\r";   // default button
    NSView *claudeCard = [self cardWithEyebrow:@"RECOMMENDED"
                                        title:@"Connect Claude in one click"
                                   symbolName:@"bolt.horizontal.circle.fill"
                                  accentColor:NSColor.systemBlueColor
                                 contentViews:@[claudeCopy, connect]];
    [stack addArrangedSubview:claudeCard];

    NSTextField *manualCopy = [self bodyLabel:
        @"For LM Studio and other MCP clients, paste this into mcp.json, save, then load a tool-capable model."];
    NSScrollView *json = [self jsonBoxWithString:[ESConnectHelper lmStudioConfigJSON]];

    NSButton *copy = [NSButton buttonWithTitle:@"Copy MCP Configuration"
                                        target:self action:@selector(copyLMStudio:)];
    copy.bezelStyle = NSBezelStyleRounded;
    NSView *manualCard = [self cardWithEyebrow:@"OTHER CLIENTS"
                                        title:@"Configure LM Studio or another MCP client"
                                   symbolName:@"doc.on.doc"
                                  accentColor:NSColor.systemTealColor
                                 contentViews:@[manualCopy, json, copy]];
    [stack addArrangedSubview:manualCard];
}

#pragma mark - Actions

- (void)connectClaude:(id)sender {
    [ESConnectHelper connectToClaudeDesktopFromWindow:self.window];
}

- (void)copyLMStudio:(NSButton *)sender {
    [ESConnectHelper copyLMStudioConfigToPasteboard];
    [self flashButton:sender title:@"Copied ✓"];
}

@end
