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
static const CGFloat kContentWidth = 492.0;

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
    [c.window center];
    [c showWindow:nil];
    [NSApp activate];   // macOS 14+; use activateIgnoringOtherApps: on older SDKs
}

+ (void)showAtStartupIfEnabled {
    if ([self showAtStartupEnabled]) [self show];
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 540, 580)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    w.title = @"Connect ES Archive";
    self = [super initWithWindow:w];
    if (self) { [self buildContent]; }
    return self;
}

- (void)buildContent {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(24, 24, 20, 24);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self titleLabel:@"Connect ES Archive"]];
    [stack addArrangedSubview:[self bodyLabel:
        @"Your AI’s memories live on this Mac. Connect the app you chat with — it talks to "
        @"ES Archive over a local connection, safe on your local machine and synced over iCloud."]];

    // The app's own connection story — the reason the window exists.
    [self addSectionsToStack:stack];

    // — Sample memories — shared, and the answer to an empty first launch:
    // connecting a client to an archive with nothing in it demonstrates very
    // little. Hidden entirely when the resource is absent, rather than offering
    // a button that cannot work.
    if ([ESBackupCommands hasSampleArchive]) {
        [self beginSectionInStack:stack];
        [stack addArrangedSubview:[self sectionHeader:@"Sample Memories"]];
        [stack addArrangedSubview:[self bodyLabel:
            @"New here? Add a set of example memories, tags and links to try searching, "
            @"following connections and reading the Archive Scope. They merge into your own "
            @"archive and stay there — nothing marks them as samples afterwards."]];
        NSButton *samples = [NSButton buttonWithTitle:@"Add Sample Memories…"
                                               target:self action:@selector(addSampleMemories:)];
        samples.bezelStyle = NSBezelStyleRounded;
        [stack addArrangedSubview:samples];
    }

    // — footer: show-at-startup preference —
    [self beginSectionInStack:stack];
    NSButton *chk = [NSButton checkboxWithTitle:@"Show at next startup"
                                         target:self action:@selector(toggleShowAtStartup:)];
    chk.state = [ESOnboardingWindowController showAtStartupEnabled]
                    ? NSControlStateValueOn : NSControlStateValueOff;
    self.showAtStartupCheckbox = chk;
    [stack addArrangedSubview:chk];

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
    [self.window setContentSize:NSMakeSize(540, stack.fittingSize.height)];
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
    l.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    return l;
}
- (NSTextField *)sectionHeader:(NSString *)s {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    return l;
}
- (NSTextField *)bodyLabel:(NSString *)s {
    NSTextField *l = [NSTextField wrappingLabelWithString:s];
    l.font = [NSFont systemFontOfSize:12];
    l.textColor = NSColor.secondaryLabelColor;
    [l.widthAnchor constraintLessThanOrEqualToConstant:kContentWidth].active = YES;
    return l;
}
- (NSBox *)separator {
    NSBox *b = [[NSBox alloc] init];
    b.boxType = NSBoxSeparator;
    [b.widthAnchor constraintEqualToConstant:kContentWidth].active = YES;
    return b;
}

- (NSScrollView *)jsonBoxWithString:(NSString *)json {
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:118].active = YES;
    [scroll.widthAnchor  constraintEqualToConstant:kContentWidth].active = YES;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
    tv.editable = NO;
    tv.selectable = YES;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.string = json;
    tv.textContainerInset = NSMakeSize(6, 6);
    tv.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = tv;
    self.jsonTextView = tv;
    return scroll;
}

@end
