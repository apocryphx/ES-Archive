//
//  ESStdioConnectController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioConnectController.h"
#import "ESConnectHelper.h"

@interface ESStdioConnectController ()
@property (copy) NSString *chatGPTSetupCommand;
@property (copy) NSString *chatGPTSkillInstruction;
@end

@implementation ESStdioConnectController

/// Claude Desktop first — the one-click path, and what most users are here for —
/// then ChatGPT desktop (Terminal setup with a manual alternative), then generic mcp.json
/// stdio hosts. Every card declares its persona with --author: the engine
/// defaults to "Claude", so a client that omits the flag writes as Claude.
- (void)addSectionsToStack:(NSStackView *)stack {
    NSTextField *claudeCopy = [self bodyLabel:
        @"Open Claude’s secure install dialog and approve ES Archive. That’s it — no configuration files to edit."];
    NSButton *connect = [NSButton buttonWithTitle:@"Connect to Claude"
                                           target:self action:@selector(connectClaude:)];
    connect.bezelStyle = NSBezelStyleRounded;
    connect.keyEquivalent = @"\r";   // default button
    NSView *claudeCard = [self cardWithEyebrow:@"Claude.ai"
                                        title:@"Connect Claude in one click"
                                   symbolName:@"bolt.horizontal.circle.fill"
                                  accentColor:NSColor.systemBlueColor
                                 contentViews:@[claudeCopy, connect]];
    [stack addArrangedSubview:claudeCard];
    [stack addArrangedSubview:[self skillsCard]];   // right after the connector it completes

    NSTextField *chatgptCopy = [self bodyLabel:
        @"Register ES Archive for ChatGPT desktop and Codex by running this command once in Terminal."];
    NSTextField *terminalSteps = [self bodyLabel:
        @"1. Click Copy Setup Command.\n"
        @"2. Press ⌘Space, type Terminal, then press Return to open it.\n"
        @"3. Paste with ⌘V and press Return to run the command.\n"
        @"4. After it succeeds, restart ChatGPT or Codex and start a new conversation. "
        @"Type /mcp to check that ES Archive is connected."];
    self.chatGPTSetupCommand = [ESConnectHelper chatGPTSetupCommand];
    NSTextField *setupCommand = [self pathLabel:self.chatGPTSetupCommand];
    NSButton *copySetup = [NSButton buttonWithTitle:@"Copy Setup Command"
                                             target:self action:@selector(copyChatGPTSetupCommand:)];
    copySetup.bezelStyle = NSBezelStyleRounded;
    NSTextField *terminalHint = [self bodyLabel:
        @"If Terminal reports “command not found” or “No such file or directory,” use the manual setup below. "
        @"Choose one setup method; this command adds or replaces the connection named es-archive. "
        @"It configures the server connection; skills are installed separately."];
    NSTextField *manualHeading = [self sectionHeader:@"Or connect through Settings"];
    NSTextField *manualIntro = [self bodyLabel:
        @"In ChatGPT, open Settings ▸ MCP servers and choose Add server."];
    NSTextField *chatgptFields = [self bodyLabel:[NSString stringWithFormat:
        @"1. Name the server ES Archive and choose STDIO.\n"
        @"2. Paste the command path below into the command field.\n"
        @"3. Add two arguments, one per row: --author and %@. Leave environment variables "
        @"and the working directory empty.", ESChatGPTDefaultAuthor]];
    NSMutableAttributedString *fieldsText = [chatgptFields.attributedStringValue mutableCopy];
    NSFont *argumentFont = [NSFont boldSystemFontOfSize:chatgptFields.font.pointSize];
    for (NSString *argument in @[@"--author", ESChatGPTDefaultAuthor]) {
        NSRange range = [fieldsText.string rangeOfString:argument];
        if (range.location != NSNotFound) {
            [fieldsText addAttribute:NSFontAttributeName value:argumentFont range:range];
            [fieldsText addAttribute:NSForegroundColorAttributeName value:NSColor.blackColor range:range];
        }
    }
    chatgptFields.attributedStringValue = fieldsText;
    NSTextField *chatgptFinish = [self bodyLabel:
        @"4. Save the server, then select Restart.\n"
        @"5. Type /mcp in the composer to check that ES Archive is connected. "
        @"Ask ChatGPT to search your archive to try it out."];
    NSTextField *chatgptNote = [self bodyLabel:
        @"The author argument names the persona used for new memories. This local setup is shared "
        @"with Codex CLI and its IDE extension; ChatGPT on the web does not read it."];
    NSTextField *skillsHeading = [self sectionHeader:@"Then install the archive skills"];
    NSTextField *skillsIntro = [self bodyLabel:
        @"1. Click Copy Instruction.\n"
        @"2. Open a conversation in ChatGPT or Codex.\n"
        @"3. Paste with ⌘V and send the message to install the archive skills."];
    self.chatGPTSkillInstruction =
        @"Install all seven skills from https://github.com/apocryphx/ES-Archive/tree/main/skills/codex. "
        @"If already installed, check whether they need updating.";
    NSTextField *skillsPrompt = [self pathLabel:self.chatGPTSkillInstruction];
    NSButton *copyInstruction = [NSButton buttonWithTitle:@"Copy Instruction"
        target:self action:@selector(copyChatGPTSkillInstruction:)];
    copyInstruction.bezelStyle = NSBezelStyleRounded;
    NSButton *chatgptHelp = [NSButton buttonWithTitle:@"ChatGPT MCP Setup Guide ↗"
                                             target:self action:@selector(openChatGPTGuide:)];
    chatgptHelp.bezelStyle = NSBezelStyleRounded;
    NSTextField *path = [self pathLabel:[ESConnectHelper serverExecutablePath]];
    NSButton *copyPath = [NSButton buttonWithTitle:@"Copy Command Path"
                                            target:self action:@selector(copyChatGPTPath:)];
    copyPath.bezelStyle = NSBezelStyleRounded;
    NSView *chatgptCard = [self cardWithEyebrow:@"CHATGPT"
                                         title:@"Connect ChatGPT and Codex"
                                    symbolName:@"bubble.left.and.bubble.right.fill"
                                   accentColor:NSColor.systemGreenColor
                                  contentViews:@[chatgptCopy, terminalSteps, setupCommand, copySetup, terminalHint,
                                      manualHeading, manualIntro, chatgptFields, path, copyPath,
                                      chatgptFinish, chatgptNote, skillsHeading, skillsIntro, skillsPrompt,
                                      copyInstruction, chatgptHelp]];
    [stack addArrangedSubview:chatgptCard];

    NSTextField *manualCopy = [self bodyLabel:[NSString stringWithFormat:
        @"For LM Studio and other MCP clients, paste this into mcp.json, save, then load a tool-capable model. "
        @"The --author value (%@) names the persona this client writes as; change it to suit.",
        ESLMStudioDefaultAuthor]];
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

- (void)openChatGPTGuide:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://learn.chatgpt.com/docs/extend/mcp?surface=app"]];
}

- (void)copyChatGPTPath:(NSButton *)sender {
    [ESConnectHelper copyServerExecutablePathToPasteboard];
    [self flashButton:sender title:@"Copied ✓"];
}

- (void)copyChatGPTSetupCommand:(NSButton *)sender {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:self.chatGPTSetupCommand forType:NSPasteboardTypeString];
    [self flashButton:sender title:@"Copied ✓"];
}

- (void)copyChatGPTSkillInstruction:(NSButton *)sender {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:self.chatGPTSkillInstruction forType:NSPasteboardTypeString];
    [self flashButton:sender title:@"Copied ✓"];
}

#pragma mark - Views

/// A single selectable monospaced line for a path — a form field's worth, not
/// the 104-pt mcp.json box, which would be mostly blank for one line.
- (NSTextField *)pathLabel:(NSString *)path {
    NSTextField *l = [NSTextField labelWithString:path];
    l.selectable = YES;
    l.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    l.lineBreakMode = NSLineBreakByCharWrapping;
    l.maximumNumberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.preferredMaxLayoutWidth = 552;
    [l.widthAnchor constraintLessThanOrEqualToConstant:552].active = YES;
    return l;
}

@end
