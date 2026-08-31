//
//  ESMemoryScopeWindowController.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryScopeWindowController.h"
#import "ESMemoryScopeView.h"
#import "ESMemoryScopeDataSource.h"
#import "ESTagCloudView.h"
#import "ESColorLUT.h"
#import "ESForceGraph.h"
#import "ESVectorEngine.h"
#import "ESCoreDataStack.h"

static const CGFloat kDetailPanelWidth = 280.0;
static NSString * const kAllPersonasTitle = @"All (witness)";

@interface ESMemoryScopeWindowController () <ESMemoryScopeViewDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) NSTabViewController *tabViewController;
@property (nonatomic, strong) ESMemoryScopeView *scopeView;
@property (nonatomic, strong) ESTagCloudView *tagCloudView;
@property (nonatomic, strong) ESMemoryScopeDataSource *dataSource;

// Status bar
@property (nonatomic, strong) NSGlassEffectView *statusBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSPopUpButton *personaPopup;  // persona / All (witness) picker

// Detail panel — a collapsible trailing inspector split-view item.
// The inspector behavior supplies the system Liquid Glass material itself,
// so detailPanel is a plain (transparent) container for the labels.
@property (nonatomic, strong) NSSplitViewItem *detailSplitItem;
@property (nonatomic, strong) NSView *detailPanel;
@property (nonatomic, strong) NSTextField *detailTitleLabel;
@property (nonatomic, strong) NSTextField *detailMetaLabel;
@property (nonatomic, strong) NSTextField *detailDateLabel;
@property (nonatomic, strong) NSScrollView *detailScrollView;
@property (nonatomic, strong) NSTextView *detailBodyView;
@end

@implementation ESMemoryScopeWindowController

+ (instancetype)shared {
    static ESMemoryScopeWindowController *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ESMemoryScopeWindowController alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    NSRect frame = NSMakeRect(0, 0, 900, 600);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.title = @"Archive Scope";
    window.minSize = NSMakeSize(600, 400);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        [self setupContent];
    }
    return self;
}

- (void)setupContent {
    NSView *content = self.window.contentView;

    // ── Tab View Controller (Archive Scope + Tag Cloud) ──
    self.scopeView = [[ESMemoryScopeView alloc] initWithFrame:NSZeroRect];
    self.scopeView.colorLUT = [ESColorLUT hotCold];
    self.scopeView.delegate = self;

    self.tagCloudView = [[ESTagCloudView alloc] initWithFrame:NSZeroRect];

    NSViewController *scopeVC = [[NSViewController alloc] init];
    scopeVC.title = @"Archive Scope";
    scopeVC.view = self.scopeView;

    NSViewController *tagCloudVC = [[NSViewController alloc] init];
    tagCloudVC.title = @"Tag Cloud";
    tagCloudVC.view = self.tagCloudView;

    self.tabViewController = [[NSTabViewController alloc] init];
    self.tabViewController.tabStyle = NSTabViewControllerTabStyleSegmentedControlOnTop;
    [self.tabViewController addChildViewController:scopeVC];
    [self.tabViewController addChildViewController:tagCloudVC];

    [self.tabViewController addObserver:self
                             forKeyPath:@"selectedTabViewItemIndex"
                                options:NSKeyValueObservingOptionNew
                                context:NULL];

    // ── Detail panel (collapsible trailing inspector split item) ──
    // A plain transparent container; the inspector item provides the glass.
    self.detailPanel = [[NSView alloc] init];

    NSViewController *detailVC = [[NSViewController alloc] init];
    detailVC.title = @"Detail";
    detailVC.view = self.detailPanel;

    [self setupDetailPanelContent];

    // ── Split view: main tab area + trailing inspector detail panel ──
    NSSplitViewItem *mainItem = [NSSplitViewItem splitViewItemWithViewController:self.tabViewController];
    mainItem.canCollapse = NO;
    mainItem.holdingPriority = NSLayoutPriorityDefaultLow;  // absorbs window resizing

    self.detailSplitItem = [NSSplitViewItem inspectorWithViewController:detailVC];
    self.detailSplitItem.canCollapse = YES;
    self.detailSplitItem.minimumThickness = kDetailPanelWidth;  // fixed-width panel
    self.detailSplitItem.maximumThickness = kDetailPanelWidth;
    self.detailSplitItem.collapsed = YES;  // start hidden

    self.splitViewController = [[NSSplitViewController alloc] init];
    [self.splitViewController addSplitViewItem:mainItem];
    [self.splitViewController addSplitViewItem:self.detailSplitItem];
    self.splitViewController.splitView.dividerStyle = NSSplitViewDividerStyleThin;

    self.splitViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.splitViewController.view];

    // ── Liquid Glass status bar (bottom) ──
    self.statusBar = [[NSGlassEffectView alloc] init];
    self.statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.statusBar];

    // Status label (left side)
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBar addSubview:self.statusLabel];

    // Persona picker (right side) — one mind, or All (witness).
    self.personaPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.personaPopup.translatesAutoresizingMaskIntoConstraints = NO;
    self.personaPopup.controlSize = NSControlSizeSmall;
    self.personaPopup.font = [NSFont systemFontOfSize:11];
    self.personaPopup.bordered = NO;
    self.personaPopup.target = self;
    self.personaPopup.action = @selector(personaPopupChanged:);
    [self.statusBar addSubview:self.personaPopup];

    // ── Layout ──
    [NSLayoutConstraint activateConstraints:@[
        // Split view fills the content area above the status bar
        [self.splitViewController.view.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.splitViewController.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.splitViewController.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.splitViewController.view.bottomAnchor constraintEqualToAnchor:self.statusBar.topAnchor],

        // Status bar pinned to bottom, full width
        [self.statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [self.statusBar.heightAnchor constraintEqualToConstant:28],

        // Status label inside bar (left), ending before the persona picker
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.statusBar.leadingAnchor constant:12],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.statusBar.centerYAnchor],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.personaPopup.leadingAnchor constant:-8],

        // Persona picker (right)
        [self.personaPopup.trailingAnchor constraintEqualToAnchor:self.statusBar.trailingAnchor constant:-8],
        [self.personaPopup.centerYAnchor constraintEqualToAnchor:self.statusBar.centerYAnchor],
    ]];

    // Data source (defaults to the primary persona) + picker to match it.
    self.dataSource = [[ESMemoryScopeDataSource alloc] init];
    self.scopeView.graph = self.dataSource.graph;
    self.scopeView.dataSource = self.dataSource;
    self.scopeView.colorByPersona = (self.dataSource.selectedPersona == nil);
    [self populatePersonaPopup];

    // Observe graph updates to restart simulation
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(graphDidUpdate:)
                                                 name:ESGraphDidUpdateNotification
                                               object:self.dataSource];

    // The vector cache warms at startup and reloads after a reindex,
    // independently of CDMemory / CDLink mutations, so the FRC delegates
    // don't fire. Without this observer, a Archive Scope opened while the
    // cache is still loading (startup) or mid-reindex builds a graph with
    // zero similarity edges that never recovers. Listen and rebuild the
    // graph once the cache is ready. (This is a startup/reindex ordering
    // concern — not an embedder-switch one: the archive runs a single
    // universal embedder, so the cache never re-warms under a new model.)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(vectorCacheReady:)
                                                 name:ESVectorCacheReadyNotification
                                               object:nil];
}

- (void)setupDetailPanelContent {
    // Title — bold, up to 2 lines
    self.detailTitleLabel = [NSTextField labelWithString:@""];
    self.detailTitleLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
    self.detailTitleLabel.maximumNumberOfLines = 2;
    self.detailTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.detailTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailPanel addSubview:self.detailTitleLabel];

    // Metadata line — "type · author · N views"
    self.detailMetaLabel = [NSTextField labelWithString:@""];
    self.detailMetaLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.detailMetaLabel.textColor = NSColor.secondaryLabelColor;
    self.detailMetaLabel.maximumNumberOfLines = 1;
    self.detailMetaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.detailMetaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailPanel addSubview:self.detailMetaLabel];

    // Date line (second row)
    self.detailDateLabel = [NSTextField labelWithString:@""];
    self.detailDateLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.detailDateLabel.textColor = NSColor.tertiaryLabelColor;
    self.detailDateLabel.maximumNumberOfLines = 1;
    self.detailDateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.detailDateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailPanel addSubview:self.detailDateLabel];

    // Scrollable body text
    self.detailScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.detailScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailScrollView.hasVerticalScroller = YES;
    self.detailScrollView.hasHorizontalScroller = NO;
    self.detailScrollView.autohidesScrollers = YES;
    self.detailScrollView.drawsBackground = NO;
    self.detailScrollView.borderType = NSNoBorder;
    [self.detailPanel addSubview:self.detailScrollView];

    self.detailBodyView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.detailBodyView.editable = NO;
    self.detailBodyView.selectable = YES;
    self.detailBodyView.drawsBackground = NO;
    self.detailBodyView.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    self.detailBodyView.textColor = NSColor.labelColor;
    self.detailBodyView.textContainerInset = NSMakeSize(0, 0);
    self.detailBodyView.autoresizingMask = NSViewWidthSizable;
    // Let text wrap within scroll view width
    self.detailBodyView.textContainer.widthTracksTextView = YES;
    self.detailBodyView.textContainer.containerSize = NSMakeSize(0, CGFLOAT_MAX);

    self.detailScrollView.documentView = self.detailBodyView;

    // Layout inside detail panel.
    // Leading/trailing constraints use priority 999 (one below required) so they
    // yield gracefully during the split-item collapse/expand transition, when the
    // panel is briefly narrower than its fixed thickness.
    NSMutableArray<NSLayoutConstraint *> *innerConstraints = [NSMutableArray array];

    void (^addLowPri)(NSLayoutConstraint *) = ^(NSLayoutConstraint *c) {
        c.priority = NSLayoutPriorityRequired - 1;
        [innerConstraints addObject:c];
    };

    // Title at top with padding
    [innerConstraints addObject:[self.detailTitleLabel.topAnchor constraintEqualToAnchor:self.detailPanel.topAnchor constant:16]];
    addLowPri([self.detailTitleLabel.leadingAnchor constraintEqualToAnchor:self.detailPanel.leadingAnchor constant:16]);
    addLowPri([self.detailTitleLabel.trailingAnchor constraintEqualToAnchor:self.detailPanel.trailingAnchor constant:-16]);

    // Meta below title
    [innerConstraints addObject:[self.detailMetaLabel.topAnchor constraintEqualToAnchor:self.detailTitleLabel.bottomAnchor constant:4]];
    addLowPri([self.detailMetaLabel.leadingAnchor constraintEqualToAnchor:self.detailPanel.leadingAnchor constant:16]);
    addLowPri([self.detailMetaLabel.trailingAnchor constraintEqualToAnchor:self.detailPanel.trailingAnchor constant:-16]);

    // Date below meta
    [innerConstraints addObject:[self.detailDateLabel.topAnchor constraintEqualToAnchor:self.detailMetaLabel.bottomAnchor constant:2]];
    addLowPri([self.detailDateLabel.leadingAnchor constraintEqualToAnchor:self.detailPanel.leadingAnchor constant:16]);
    addLowPri([self.detailDateLabel.trailingAnchor constraintEqualToAnchor:self.detailPanel.trailingAnchor constant:-16]);

    // Scroll view fills remaining space
    [innerConstraints addObject:[self.detailScrollView.topAnchor constraintEqualToAnchor:self.detailDateLabel.bottomAnchor constant:12]];
    addLowPri([self.detailScrollView.leadingAnchor constraintEqualToAnchor:self.detailPanel.leadingAnchor constant:16]);
    addLowPri([self.detailScrollView.trailingAnchor constraintEqualToAnchor:self.detailPanel.trailingAnchor constant:-12]);
    [innerConstraints addObject:[self.detailScrollView.bottomAnchor constraintEqualToAnchor:self.detailPanel.bottomAnchor constant:-8]];

    [NSLayoutConstraint activateConstraints:innerConstraints];
}

- (void)dealloc {
    [self.tabViewController removeObserver:self forKeyPath:@"selectedTabViewItemIndex"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (object == self.tabViewController &&
        [keyPath isEqualToString:@"selectedTabViewItemIndex"]) {
        if (self.tabViewController.selectedTabViewItemIndex != 0) {
            self.scopeView.selectedNode = nil;
            [self setDetailPanelVisible:NO animated:YES];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Persona Picker

// Every distinct author in the archive is a persona — including unbound ones
// (e.g. a persona with records but no listening port), which portAuthorMap
// would miss. Fetch straight from CDMemory.
- (NSArray<NSString *> *)distinctArchiveAuthors {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    req.includesSubentities = NO;
    req.resultType = NSDictionaryResultType;
    req.propertiesToFetch = @[@"author"];
    req.returnsDistinctResults = YES;

    NSArray<NSDictionary *> *rows = [ctx executeFetchRequest:req error:nil] ?: @[];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *row in rows) {
        NSString *a = row[@"author"];
        if (a.length > 0) [seen addObject:a];
    }
    return [seen.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)populatePersonaPopup {
    [self.personaPopup removeAllItems];
    [self.personaPopup addItemsWithTitles:[self distinctArchiveAuthors]];
    [self.personaPopup.menu addItem:[NSMenuItem separatorItem]];
    [self.personaPopup addItemWithTitle:kAllPersonasTitle];

    NSString *sel = self.dataSource.selectedPersona;
    [self.personaPopup selectItemWithTitle:sel ?: kAllPersonasTitle];
}

- (void)personaPopupChanged:(NSPopUpButton *)sender {
    NSString *title = sender.titleOfSelectedItem;
    BOOL all = [title isEqualToString:kAllPersonasTitle];
    self.scopeView.colorByPersona = all;
    [self.dataSource selectPersona:all ? nil : title];  // rebuilds; posts graphDidUpdate
    [self.scopeView resetToFit];
}

#pragma mark - Window Lifecycle

- (void)showWindow:(id)sender {
    [super showWindow:sender];

    // Repopulate the picker (authors may have changed) and rebuild.
    [self populatePersonaPopup];
    [self.dataSource buildGraph];
    [self.scopeView resetToFit];
    [self.scopeView startSimulation];
    [self updateStatus];

    // Close detail panel when reopening (fresh state)
    [self setDetailPanelVisible:NO animated:NO];

    // Periodic status update while simulation runs
    [NSTimer scheduledTimerWithTimeInterval:0.5
                                    repeats:YES
                                      block:^(NSTimer *timer) {
        if (!self.window.isVisible) {
            [timer invalidate];
            return;
        }
        [self updateStatus];
    }];
}

#pragma mark - ESMemoryScopeViewDelegate

- (void)memoryScopeView:(ESMemoryScopeView *)view didSelectNode:(nullable ESGraphNode *)node {
    if (node) {
        NSDictionary *detail = [self.dataSource memoryDetailForNode:node];
        [self populateDetailPanelWithInfo:detail];
        [self setDetailPanelVisible:YES animated:YES];
    } else {
        [self setDetailPanelVisible:NO animated:YES];
    }
}

#pragma mark - Detail Panel

- (void)populateDetailPanelWithInfo:(NSDictionary *)info {
    // Title
    self.detailTitleLabel.stringValue = info[@"title"] ?: @"Untitled";

    // Metadata line 1: "type · author · N views"
    NSMutableArray<NSString *> *metaParts = [NSMutableArray array];

    NSString *type = info[@"type"];
    if (type.length > 0) {
        [metaParts addObject:type];
    }

    NSString *author = info[@"author"];
    if (author.length > 0) {
        [metaParts addObject:author];
    }

    NSNumber *accessCount = info[@"accessCount"];
    if (accessCount != nil) {
        [metaParts addObject:[NSString stringWithFormat:@"%@ views", accessCount]];
    }

    self.detailMetaLabel.stringValue = [metaParts componentsJoinedByString:@" · "];

    // Metadata line 2: date
    NSString *dateCreated = info[@"dateCreated"];
    self.detailDateLabel.stringValue = dateCreated ?: @"";

    // Body + comments as attributed string
    NSMutableAttributedString *content = [[NSMutableAttributedString alloc] init];

    // Body
    NSString *body = info[@"body"] ?: @"";
    NSDictionary *bodyAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    [content appendAttributedString:[[NSAttributedString alloc] initWithString:body attributes:bodyAttrs]];

    // Comments (marginalia)
    NSArray<NSDictionary *> *comments = info[@"comments"];
    if (comments.count > 0) {
        // Separator
        NSDictionary *sepAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor
        };
        [content appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"\n\n— marginalia —\n" attributes:sepAttrs]];

        NSDictionary *noteAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.secondaryLabelColor
        };
        NSDictionary *headerAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor
        };

        for (NSDictionary *c in comments) {
            // Header: "author · date"
            NSMutableArray *parts = [NSMutableArray array];
            if ([c[@"author"] length] > 0) [parts addObject:c[@"author"]];
            if ([c[@"date"] length] > 0) [parts addObject:c[@"date"]];
            NSString *header = [parts componentsJoinedByString:@" · "];
            if (header.length > 0) {
                [content appendAttributedString:[[NSAttributedString alloc]
                    initWithString:[NSString stringWithFormat:@"\n%@\n", header] attributes:headerAttrs]];
            } else {
                [content appendAttributedString:[[NSAttributedString alloc]
                    initWithString:@"\n" attributes:headerAttrs]];
            }
            [content appendAttributedString:[[NSAttributedString alloc]
                initWithString:c[@"body"] ?: @"" attributes:noteAttrs]];
        }
    }

    [self.detailBodyView.textStorage setAttributedString:content];

    // Scroll to top
    [self.detailBodyView scrollToBeginningOfDocument:nil];
}

- (void)setDetailPanelVisible:(BOOL)visible animated:(BOOL)animated {
    BOOL shouldCollapse = !visible;

    // Already at target
    if (self.detailSplitItem.isCollapsed == shouldCollapse) return;

    if (animated) {
        // Setting collapsed through the animator gives the system slide animation.
        self.detailSplitItem.animator.collapsed = shouldCollapse;
    } else {
        self.detailSplitItem.collapsed = shouldCollapse;
    }
}

#pragma mark - Controls

- (void)graphDidUpdate:(NSNotification *)note {
    if (!self.window.isVisible) return;
    [self.scopeView startSimulation];
    [self updateStatus];
}

- (void)vectorCacheReady:(NSNotification *)note {
    if (!self.window.isVisible) return;
    // Cache shape changed (dimension, vector population). The current
    // graph may be stale or empty (no similarity edges if it built during
    // a backfill). Rebuild from scratch and restart simulation.
    [self.dataSource buildGraph];
    [self.scopeView resetToFit];
    [self.scopeView startSimulation];
    [self updateStatus];
}

- (void)updateStatus {
    ESForceGraph *g = self.dataSource.graph;
    NSUInteger nodeCount = g.visibleNodes.count;
    NSUInteger totalNodes = g.nodes.count;
    NSArray<ESGraphEdge *> *edges = g.visibleEdges;

    NSUInteger linkEdges = 0, simEdges = 0;
    NSMutableSet<NSManagedObjectID *> *connected = [NSMutableSet set];
    for (ESGraphEdge *e in edges) {
        if (e.isExplicitLink) linkEdges++;
        else simEdges++;
        if (e.source.memoryID) [connected addObject:e.source.memoryID];
        if (e.target.memoryID) [connected addObject:e.target.memoryID];
    }

    // Isolated = memories with no neighbor at all. Every embeddable memory
    // gets one nearest-neighbor edge, so a nonzero count flags memories with
    // no vector (summary-less \u2192 also invisible to semantic search).
    NSUInteger isolated = 0;
    for (ESGraphNode *n in g.visibleNodes) {
        if (n.memoryID && ![connected containsObject:n.memoryID]) isolated++;
    }

    NSString *status = [NSString stringWithFormat:
                        @"Nodes: %lu/%lu    Links: %lu    Sim: %lu    Isolated: %lu    %@",
                        (unsigned long)nodeCount,
                        (unsigned long)totalNodes,
                        (unsigned long)linkEdges,
                        (unsigned long)simEdges,
                        (unsigned long)isolated,
                        g.isSettled ? @"Settled" : @"Simulating\u2026"];
    self.statusLabel.stringValue = status;
}

@end
