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
    [self beginSectionInStack:stack];
    [stack addArrangedSubview:[self sectionHeader:@"Connect to Claude Desktop"]];
    [stack addArrangedSubview:[self bodyLabel:
        @"One click. Claude Desktop will ask you to confirm the install."]];

    NSButton *connect = [NSButton buttonWithTitle:@"Connect"
                                           target:self action:@selector(connectClaude:)];
    connect.bezelStyle = NSBezelStyleRounded;
    connect.keyEquivalent = @"\r";   // default button
    [stack addArrangedSubview:connect];

    [self beginSectionInStack:stack];
    [stack addArrangedSubview:[self sectionHeader:@"LM Studio & other MCP clients"]];
    [stack addArrangedSubview:[self bodyLabel:
        @"Paste this into LM Studio’s mcp.json (Program ▸ Edit mcp.json), then load a "
        @"tool-capable model:"]];
    [stack addArrangedSubview:[self jsonBoxWithString:[ESConnectHelper lmStudioConfigJSON]]];

    NSButton *copy = [NSButton buttonWithTitle:@"Copy Configuration"
                                        target:self action:@selector(copyLMStudio:)];
    copy.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:copy];
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
