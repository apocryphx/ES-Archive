//
//  ESSkillInstallController.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESSkillInstallController.h"
#import "ESConnectHelper.h"
#import "ESZip.h"

static const CGFloat kWindowWidth = 620.0;
static const CGFloat kRowTextWidth = 380.0;

/// One bundled skill: its folder name, the SKILL.md text, and the description
/// lifted from the YAML frontmatter for the row.
@interface ESBundledSkill : NSObject
@property (copy) NSString *name;
@property (copy) NSString *markdown;
@property (copy) NSString *summary;
@end
@implementation ESBundledSkill
@end

@interface ESSkillInstallController ()
@property (copy) NSArray<ESBundledSkill *> *skills;
/// Per skill name: the row's Install button and its (initially hidden)
/// checkmark, so an install can flip the row to its "done" look.
@property (strong) NSMutableDictionary<NSString *, NSButton *> *installButtons;
@property (strong) NSMutableDictionary<NSString *, NSImageView *> *checkmarks;
@end

@implementation ESSkillInstallController

+ (instancetype)shared {
    static ESSkillInstallController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

+ (void)show {
    ESSkillInstallController *c = [self shared];
    if (!c.window.isVisible) [c.window center];
    [c showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kWindowWidth, 520)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.title = @"Install Claude Skills";
    self = [super initWithWindow:w];
    if (self) {
        _skills = [self.class loadBundledSkills];
        _installButtons = [NSMutableDictionary dictionary];
        _checkmarks = [NSMutableDictionary dictionary];
        [self buildContent];
    }
    return self;
}

#pragma mark - Bundled skills

+ (NSArray<ESBundledSkill *> *)loadBundledSkills {
    NSURL *root = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Skills" isDirectory:YES];
    NSArray<NSURL *> *folders = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    NSMutableArray<ESBundledSkill *> *skills = [NSMutableArray array];
    for (NSURL *folder in folders) {
        NSURL *file = [folder URLByAppendingPathComponent:@"SKILL.md"];
        NSString *text = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:NULL];
        if (!text.length) continue;
        ESBundledSkill *skill = [[ESBundledSkill alloc] init];
        skill.name = folder.lastPathComponent;
        skill.markdown = text;
        skill.summary = [self descriptionFromFrontmatter:text] ?: @"";
        [skills addObject:skill];
    }
    // The overview skill is the entry point that loads the others — list it first,
    // the rest alphabetically.
    [skills sortUsingComparator:^NSComparisonResult(ESBundledSkill *a, ESBundledSkill *b) {
        BOOL ao = [a.name hasSuffix:@"-overview"], bo = [b.name hasSuffix:@"-overview"];
        if (ao != bo) return ao ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name];
    }];
    return skills;
}

/// The `description:` value of the leading YAML frontmatter. Handles the plain
/// one-line form and the folded block (`>` / `>-`) the suite uses, where the
/// value continues on the following indented lines.
+ (nullable NSString *)descriptionFromFrontmatter:(NSString *)text {
    if (![text hasPrefix:@"---"]) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *parts = nil;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if ([line hasPrefix:@"---"]) break;
        if (parts) {
            if (line.length == 0 || ![line hasPrefix:@" "]) break;   // block ended
            [parts addObject:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
            continue;
        }
        if ([line hasPrefix:@"description:"]) {
            NSString *value = [[line substringFromIndex:@"description:".length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([value isEqualToString:@">"] || [value isEqualToString:@">-"]) {
                parts = [NSMutableArray array];
            } else {
                return value;
            }
        }
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

/// The first sentence of the description — what the skill is for, without the
/// trigger list that follows it. The full text is one Read click away.
+ (NSString *)shortSummary:(NSString *)summary {
    NSRange r = [summary rangeOfString:@". "];
    if (r.location == NSNotFound) return summary;
    return [summary substringToIndex:r.location + 1];
}

#pragma mark - Layout

- (void)buildContent {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(24, 28, 20, 28);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"Install Claude Skills"];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    [stack addArrangedSubview:title];

    NSTextField *intro = [self bodyLabel:
        @"Skills teach Claude how to use the archive well: when to store, how to research, "
        @"how to curate. Install opens Claude Desktop, which asks you to confirm each skill "
        @"and replaces any earlier copy of the same name. Read shows the skill text first."];
    [stack addArrangedSubview:intro];
    [stack setCustomSpacing:18 afterView:intro];

    if (self.skills.count == 0) {
        NSTextField *missing = [self bodyLabel:
            @"No skills are bundled with this build. They are published at "
            @"https://github.com/apocryphx/ES-Archive/tree/main/skills/claude."];
        [stack addArrangedSubview:missing];
    }

    for (ESBundledSkill *skill in self.skills) {
        NSView *row = [self rowForSkill:skill];
        [stack addArrangedSubview:row];
        NSBox *sep = [[NSBox alloc] init];
        sep.boxType = NSBoxSeparator;
        [sep.widthAnchor constraintEqualToConstant:kWindowWidth - 56].active = YES;
        [stack addArrangedSubview:sep];
    }

    // NSStackView's fitting height does not reliably include its trailing edge
    // inset when the final arranged view is a separator; pad explicitly.
    NSView *bottomSpacer = [[NSView alloc] init];
    [bottomSpacer.heightAnchor constraintEqualToConstant:4].active = YES;
    [stack addArrangedSubview:bottomSpacer];

    NSView *content = self.window.contentView;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    [content layoutSubtreeIfNeeded];
    [self.window setContentSize:NSMakeSize(kWindowWidth, stack.fittingSize.height)];
}

- (NSView *)rowForSkill:(ESBundledSkill *)skill {
    NSTextField *name = [NSTextField labelWithString:skill.name];
    name.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *summary = [self bodyLabel:[self.class shortSummary:skill.summary]];
    [summary.widthAnchor constraintEqualToConstant:kRowTextWidth].active = YES;

    NSStackView *text = [[NSStackView alloc] init];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 3;
    [text addArrangedSubview:name];
    [text addArrangedSubview:summary];

    NSButton *read = [NSButton buttonWithTitle:@"Read" target:self action:@selector(readSkill:)];
    read.bezelStyle = NSBezelStyleRounded;
    read.identifier = skill.name;
    NSButton *install = [NSButton buttonWithTitle:@"Install" target:self action:@selector(installSkill:)];
    install.bezelStyle = NSBezelStyleRounded;
    install.bezelColor = NSColor.systemBlueColor;
    install.identifier = skill.name;
    self.installButtons[skill.name] = install;

    // Invisible until the skill has been handed to Claude Desktop.
    NSImageView *check = [[NSImageView alloc] init];
    check.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                            accessibilityDescription:@"Installed"];
    check.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16
                                                                                 weight:NSFontWeightSemibold];
    check.contentTintColor = NSColor.systemGreenColor;
    check.alphaValue = 0;   // not hidden: NSStackView would drop its slot and shift the buttons
    [check.widthAnchor constraintEqualToConstant:20].active = YES;
    self.checkmarks[skill.name] = check;

    NSView *spring = [[NSView alloc] init];
    [spring setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 8;
    [row addArrangedSubview:text];
    [row addArrangedSubview:spring];
    [row addArrangedSubview:read];
    [row addArrangedSubview:install];
    [row addArrangedSubview:check];
    // The row aligns to its top edge; the symbol is shorter than the button,
    // so centre it on the button explicitly.
    [check.centerYAnchor constraintEqualToAnchor:install.centerYAnchor].active = YES;
    [row.widthAnchor constraintEqualToConstant:kWindowWidth - 56].active = YES;
    return row;
}

- (NSTextField *)bodyLabel:(NSString *)s {
    NSTextField *l = [NSTextField wrappingLabelWithString:s];
    l.font = [NSFont systemFontOfSize:13];
    l.textColor = NSColor.secondaryLabelColor;
    [l.widthAnchor constraintLessThanOrEqualToConstant:kWindowWidth - 56].active = YES;
    return l;
}

- (nullable ESBundledSkill *)skillNamed:(NSString *)name {
    for (ESBundledSkill *s in self.skills) if ([s.name isEqualToString:name]) return s;
    return nil;
}

#pragma mark - Actions

- (void)readSkill:(NSButton *)sender {
    ESBundledSkill *skill = [self skillNamed:sender.identifier];
    if (!skill) return;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 420)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    tv.string = skill.markdown;
    tv.textContainerInset = NSMakeSize(8, 8);
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    scroll.documentView = tv;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = skill.name;
    alert.informativeText = @"This is the SKILL.md Claude Desktop will install.";
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"Install"];
    [alert addButtonWithTitle:@"Close"];
    // Lay the alert out now so the text view has grown to its document height;
    // otherwise it lands scrolled partway down when the sheet appears. Start
    // the reader at the top, and again once the sheet is on screen.
    [alert layout];
    [tv scrollRangeToVisible:NSMakeRange(0, 0)];
    [scroll.contentView scrollToPoint:NSZeroPoint];
    [scroll reflectScrolledClipView:scroll.contentView];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self installSkills:@[skill]];
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [scroll.contentView scrollToPoint:NSZeroPoint];
        [scroll reflectScrolledClipView:scroll.contentView];
    });
}

- (void)installSkill:(NSButton *)sender {
    ESBundledSkill *skill = [self skillNamed:sender.identifier];
    if (skill) [self installSkills:@[skill]];
}

/// Pack each skill as `<name>.skill` in Application Support/ES Archive/Skills
/// and open them in Claude Desktop, which shows one confirmation per file.
- (void)installSkills:(NSArray<ESBundledSkill *> *)skills {
    NSURL *folder = [[ESConnectHelper appSupportFolder]
        URLByAppendingPathComponent:@"Skills" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (ESBundledSkill *skill in skills) {
        NSData *md = [skill.markdown dataUsingEncoding:NSUTF8StringEncoding];
        NSString *entry = [NSString stringWithFormat:@"%@/SKILL.md", skill.name];
        NSData *zip = [ESZip archiveWithEntries:@[ @{ @"name": entry, @"data": md } ]];
        NSURL *file = [folder URLByAppendingPathComponent:
                       [skill.name stringByAppendingPathExtension:@"skill"]];
        NSError *err = nil;
        if (![zip writeToURL:file options:NSDataWritingAtomic error:&err]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:@"Couldn’t prepare %@", skill.name];
            alert.informativeText = err.localizedDescription ?: @"";
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        [files addObject:file];
    }
    if (files.count == 0) return;
    [ESConnectHelper openInClaudeDesktop:files fromWindow:self.window
                                 failure:@"The skill package could not be handed to Claude Desktop."];
    for (ESBundledSkill *skill in skills) [self markInstalled:skill];
}

/// The row's "done" look: the Install button drops its blue and a green
/// checkmark appears beside it. It stays clickable — reinstalling is how a
/// user updates a skill after an app update.
- (void)markInstalled:(ESBundledSkill *)skill {
    NSButton *button = self.installButtons[skill.name];
    button.bezelColor = nil;
    self.checkmarks[skill.name].alphaValue = 1;
}

@end
