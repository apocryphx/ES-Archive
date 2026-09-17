//
//  ESOnboardingWindowController.m
//  ES Archive
//

#import "ESOnboardingWindowController.h"
#import "ESBackupCommands.h"
#import "ESMemoryScopeWindowController.h"

// Whether the Connect window auto-appears at launch. Default YES; the
// "Show at next startup" checkbox writes it.
static NSString * const kShowAtStartupKey = @"ESOnboardingShowAtStartup";
static const CGFloat kWindowWidth = 720.0;
static const CGFloat kCardWidth = 656.0;
static const CGFloat kCardBodyWidth = 552.0;

@interface ESOnboardingWindowController ()
@property (weak) NSButton *showAtStartupCheckbox;
+ (BOOL)showAtStartupEnabled;
@end

@implementation ESOnboardingWindowController

/// One cached instance PER CLASS. A plain dispatch_once static would be shared
/// by the base and every subclass, so the first app to open its window would
/// hand its instance to the other — harmless today, since each target links only
/// one subclass, but exactly the kind of latent cross-target bug this split is
/// meant to remove.
+ (instancetype)sharedController {
    static NSMutableDictionary<NSString *, ESOnboardingWindowController *> *byClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ byClass = [NSMutableDictionary dictionary]; });

    NSString *key = NSStringFromClass(self);
    ESOnboardingWindowController *controller = byClass[key];
    if (!controller) {
        controller = [[self alloc] init];
        byClass[key] = controller;
    }
    return controller;
}

+ (BOOL)showAtStartupEnabled {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kShowAtStartupKey];
    return (v == nil) ? YES : [v boolValue];   // default: on
}

+ (void)show {
    ESOnboardingWindowController *c = [self sharedController];
    NSWindow *w = c.window;
    [w center];
    // Since macOS 14 an app cannot take focus from the active app on its own:
    // -activate below is a request, and when Claude Desktop is already in front
    // (the host promoted by re-election a few seconds into Desktop's launch) it
    // is declined and this window would open one layer behind Desktop, unseen.
    // Onboarding exists to be seen once, so it floats above everything until the
    // user engages with it — the first time it becomes key it drops to a normal
    // window. If activation does succeed (hand launch, nothing in front) the
    // window is key at once and the float is over before it is visible.
    w.level = NSFloatingWindowLevel;
    __block id token = nil;
    token = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidBecomeKeyNotification
                                                            object:w
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) {
        w.level = NSNormalWindowLevel;
        if (token) { [NSNotificationCenter.defaultCenter removeObserver:token]; token = nil; }
    }];
    [c showWindow:nil];
    [NSApp activate];   // macOS 14+; use activateIgnoringOtherApps: on older SDKs
}

+ (void)showAtStartupIfEnabled {
    if ([self showAtStartupEnabled]) [self show];
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, kWindowWidth, 700)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.title = @"Connect ES Archive";
    w.titleVisibility = NSWindowTitleHidden;
    w.titlebarAppearsTransparent = YES;
    w.movableByWindowBackground = YES;
    self = [super initWithWindow:w];
    if (self) { [self buildContent]; }
    return self;
}

- (void)buildContent {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.edgeInsets = NSEdgeInsetsMake(30, 32, 22, 32);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *appIcon = [[NSImageView alloc] init];
    appIcon.image = NSApplication.sharedApplication.applicationIconImage;
    appIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [appIcon.widthAnchor constraintEqualToConstant:58].active = YES;
    [appIcon.heightAnchor constraintEqualToConstant:58].active = YES;

    NSStackView *heading = [[NSStackView alloc] init];
    heading.orientation = NSUserInterfaceLayoutOrientationVertical;
    heading.alignment = NSLayoutAttributeLeading;
    heading.spacing = 5;
    [heading addArrangedSubview:[self titleLabel:@"Connect your AI"]];
    [heading addArrangedSubview:[self bodyLabel:
        @"Choose a client below. ES Archive stays on this Mac and syncs privately through iCloud."]];

    NSStackView *hero = [[NSStackView alloc] init];
    hero.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hero.alignment = NSLayoutAttributeCenterY;
    hero.spacing = 18;
    [hero addArrangedSubview:appIcon];
    [hero addArrangedSubview:heading];
    [stack addArrangedSubview:hero];
    [stack setCustomSpacing:24 afterView:hero];

    // The app's own connection story — the reason the window exists.
    [self addSectionsToStack:stack];

    // — Sample memories — shared, and the answer to an empty first launch:
    // connecting a client to an archive with nothing in it demonstrates very
    // little. Hidden entirely when the resource is absent, rather than offering
    // a button that cannot work.
    if ([ESBackupCommands hasSampleArchive]) {
        NSTextField *demoCopy = [self bodyLabel:
            @"Add example memories, tags, and links, then explore search, connections, and Memory Scope. "
            @"They merge into your archive as regular entries."];
        NSButton *samples = [NSButton buttonWithTitle:@"Import Demo Archive…"
                                               target:self action:@selector(addSampleMemories:)];
        samples.bezelStyle = NSBezelStyleRounded;
        NSView *demoCard = [self cardWithEyebrow:@"OPTIONAL"
                                          title:@"Start with something to explore"
                                     symbolName:@"sparkles"
                                    accentColor:NSColor.systemPurpleColor
                                   contentViews:@[demoCopy, samples]];
        [stack addArrangedSubview:demoCard];
    }

    // — footer: show-at-startup preference —
    NSButton *chk = [NSButton checkboxWithTitle:@"Show at next startup"
                                         target:self action:@selector(toggleShowAtStartup:)];
    chk.state = [ESOnboardingWindowController showAtStartupEnabled]
                    ? NSControlStateValueOn : NSControlStateValueOff;
    self.showAtStartupCheckbox = chk;
    NSTextField *footerHint = [NSTextField labelWithString:
        @"You can reopen this window from Help ▸ Connect ES Archive."];
    footerHint.font = [NSFont systemFontOfSize:11];
    footerHint.textColor = NSColor.tertiaryLabelColor;

    NSStackView *footer = [[NSStackView alloc] init];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeFirstBaseline;
    footer.spacing = 12;
    [footer addArrangedSubview:chk];
    [footer addArrangedSubview:footerHint];
    [stack setCustomSpacing:14 afterView:stack.arrangedSubviews.lastObject];
    [stack addArrangedSubview:footer];

    // As with card edge insets, the root stack's trailing inset is not always
    // reflected in its fitting height. Keep the footer visibly clear of the
    // bottom window frame regardless of the current control metrics.
    NSView *windowBottomSpacer = [[NSView alloc] init];
    [windowBottomSpacer.heightAnchor constraintEqualToConstant:12].active = YES;
    [stack addArrangedSubview:windowBottomSpacer];

    NSView *content = self.window.contentView;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor      constraintEqualToAnchor:content.topAnchor],
    ]];
    // Size the window to the stack's actual fitting height — no trailing blank
    // space, no clipping, regardless of how the copy wraps or how many sections
    // the subclass added.
    [content layoutSubtreeIfNeeded];
    [self.window setContentSize:NSMakeSize(kWindowWidth, stack.fittingSize.height)];
}

#pragma mark - Subclass hook (base: nothing)

- (void)addSectionsToStack:(NSStackView *)stack {}

#pragma mark - Actions

- (void)addSampleMemories:(NSButton *)sender {
    if (![ESBackupCommands presentSampleMemoriesInstall]) return;

    // Show the payoff. A graph of memories and their links is the one view that
    // makes the archive legible at a glance, and it is the reason for adding
    // samples at all — so open it rather than leaving the user on this window
    // wondering what changed. Vectors are still encoding in the background, so
    // similarity edges keep arriving for a moment after it appears.
    [[ESMemoryScopeWindowController shared] showWindow:self];
}

- (void)toggleShowAtStartup:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setBool:(sender.state == NSControlStateValueOn)
                                          forKey:kShowAtStartupKey];
}

- (void)flashButton:(NSButton *)button title:(NSString *)title {
    NSString *original = button.title;
    button.title = title;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ button.title = original; });
}

#pragma mark - View factories

- (void)beginSectionInStack:(NSStackView *)stack {
    if (stack.arrangedSubviews.count > 0) {
        [stack setCustomSpacing:18 afterView:stack.arrangedSubviews.lastObject];
    }
    [stack addArrangedSubview:[self separator]];
}

- (NSTextField *)titleLabel:(NSString *)s {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:26 weight:NSFontWeightBold];
    return l;
}
- (NSTextField *)sectionHeader:(NSString *)s {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    return l;
}
- (NSTextField *)bodyLabel:(NSString *)s {
    NSTextField *l = [NSTextField wrappingLabelWithString:s];
    l.font = [NSFont systemFontOfSize:13];
    l.textColor = NSColor.secondaryLabelColor;
    [l.widthAnchor constraintLessThanOrEqualToConstant:kCardBodyWidth].active = YES;
    return l;
}
- (NSBox *)separator {
    NSBox *b = [[NSBox alloc] init];
    b.boxType = NSBoxSeparator;
    [b.widthAnchor constraintEqualToConstant:kCardWidth].active = YES;
    return b;
}

- (NSView *)cardWithEyebrow:(NSString *)eyebrow
                      title:(NSString *)title
                 symbolName:(NSString *)symbolName
                accentColor:(NSColor *)accentColor
               contentViews:(NSArray<NSView *> *)contentViews {
    NSImageView *symbol = [[NSImageView alloc] init];
    symbol.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
    symbol.contentTintColor = accentColor;
    symbol.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:22
                                                                                  weight:NSFontWeightMedium];
    symbol.imageScaling = NSImageScaleProportionallyUpOrDown;

    NSView *symbolWell = [[NSView alloc] init];
    symbolWell.wantsLayer = YES;
    symbolWell.layer.cornerRadius = 12;
    symbolWell.layer.backgroundColor = [[accentColor colorWithAlphaComponent:0.12] CGColor];
    [symbolWell.widthAnchor constraintEqualToConstant:48].active = YES;
    [symbolWell.heightAnchor constraintEqualToConstant:48].active = YES;
    symbol.translatesAutoresizingMaskIntoConstraints = NO;
    [symbolWell addSubview:symbol];
    [NSLayoutConstraint activateConstraints:@[
        [symbol.centerXAnchor constraintEqualToAnchor:symbolWell.centerXAnchor],
        [symbol.centerYAnchor constraintEqualToAnchor:symbolWell.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:26],
        [symbol.heightAnchor constraintEqualToConstant:26],
    ]];

    NSTextField *eyebrowLabel = [NSTextField labelWithString:eyebrow];
    eyebrowLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
    eyebrowLabel.textColor = accentColor;

    NSStackView *copy = [[NSStackView alloc] init];
    copy.orientation = NSUserInterfaceLayoutOrientationVertical;
    copy.alignment = NSLayoutAttributeLeading;
    copy.spacing = 8;
    [copy addArrangedSubview:eyebrowLabel];
    [copy addArrangedSubview:[self sectionHeader:title]];
    for (NSView *view in contentViews) [copy addArrangedSubview:view];

    // NSStackView's fitting height does not reliably include its trailing edge
    // inset when the final arranged view is a button. An explicit spacer keeps
    // the action clear of the card border in every onboarding variant.
    NSView *bottomSpacer = [[NSView alloc] init];
    [bottomSpacer.heightAnchor constraintEqualToConstant:10].active = YES;
    [copy addArrangedSubview:bottomSpacer];

    NSStackView *card = [[NSStackView alloc] init];
    card.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    card.alignment = NSLayoutAttributeTop;
    card.spacing = 16;
    card.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    card.wantsLayer = YES;
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    card.layer.borderColor = NSColor.separatorColor.CGColor;
    card.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    [card addArrangedSubview:symbolWell];
    [card addArrangedSubview:copy];
    [card.widthAnchor constraintEqualToConstant:kCardWidth].active = YES;
    return card;
}

- (NSScrollView *)jsonBoxWithString:(NSString *)json {
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:104].active = YES;
    [scroll.widthAnchor  constraintEqualToConstant:kCardBodyWidth].active = YES;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    tv.string = json;
    tv.textContainerInset = NSMakeSize(6, 6);
    tv.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = tv;
    self.jsonTextView = tv;
    return scroll;
}

@end
