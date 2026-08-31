//
//  ViewController.m
//  ES Archive
//
//  Created by Kolja Wawrowsky on 3/2/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESSystemPulseViewController.h"
#import "MCPServer.h"
#import "ESServerConfig.h"
#import "ESLog.h"
#import "ESCoreDataStack.h"
#import "ESVectorEngine.h"
#import "ESMemoryNotifications.h"
#import "CDMemory.h"
#import "CDVector.h"
#import "MCPToolDispatcher.h"
#import "AppDelegate.h"
#import "ESMemoryScopeWindowController.h"
#import "CDTag.h"
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>

static void * const kMCPServerPortContext = (void *)&kMCPServerPortContext;

// Ring-buffer cap for the MCP Tool Calls log pane. Oldest lines are trimmed
// from the top once the total exceeds this count.
static const NSUInteger kLogMaxLines = 50;

// Longest tool name is ~23 chars ("archive_recall_attachment" = 24).
// Pad to 24 so the quoted argument column stays vertically aligned.
static const NSUInteger kToolNameColumnWidth = 24;

// Identifying-argument truncation cap (display only; the tool itself sees
// the full argument).
static const NSUInteger kArgMaxChars = 30;

#pragma mark - ESCloudKitDot (file-private)

typedef NS_ENUM(NSInteger, ESCloudKitDotState) {
    ESCloudKitDotStateIdle,
    ESCloudKitDotStateActive,
    ESCloudKitDotStateSuccess,
    ESCloudKitDotStateError,
};

@interface ESCloudKitDot : NSView
@property (nonatomic, copy)   NSString *label;                // "Setup" | "Import" | "Export"
@property (nonatomic, assign) BOOL isLink;                    // stays green on success, no fade
@property (nonatomic, assign) ESCloudKitDotState state;
@property (nonatomic, strong, nullable) NSDate *lastEventDate;
@property (nonatomic, strong, nullable) NSError *lastError;
- (void)applyState:(ESCloudKitDotState)state timestamp:(NSDate *)ts error:(nullable NSError *)error;
- (void)fadeToIdle;
@end

@implementation ESCloudKitDot

- (instancetype)init {
    self = [super initWithFrame:NSMakeRect(0, 0, 8, 8)];
    if (!self) return nil;

    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 4;
    _state = ESCloudKitDotStateIdle;
    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:8],
        [self.heightAnchor constraintEqualToConstant:8],
    ]];
    [self applyAppearance];
    return self;
}

- (void)applyState:(ESCloudKitDotState)state
         timestamp:(NSDate *)ts
             error:(nullable NSError *)error {
    self.lastEventDate = ts;
    self.lastError = error;
    self.state = state;
    [self applyAppearance];
    [self refreshTooltip];

    // Burst handling: Import/Export dots fade back to idle ~0.3s after the
    // LAST event in a run. Cancel any pending fade and reschedule.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(fadeToIdle)
                                               object:nil];
    if (state == ESCloudKitDotStateSuccess && !self.isLink) {
        [self performSelector:@selector(fadeToIdle) withObject:nil afterDelay:0.3];
    }
}

- (void)fadeToIdle {
    // Only demote a plain Success → Idle. If the user has since entered
    // Active or Error, leave it alone.
    if (self.state == ESCloudKitDotStateSuccess) {
        self.state = ESCloudKitDotStateIdle;
        [self applyAppearance];
    }
}

- (void)applyAppearance {
    [self.layer removeAnimationForKey:@"opacityPulse"];
    self.layer.opacity = 1.0;

    switch (self.state) {
        case ESCloudKitDotStateIdle:
            self.layer.backgroundColor = NSColor.tertiaryLabelColor.CGColor;
            break;
        case ESCloudKitDotStateActive:
            self.layer.backgroundColor = NSColor.systemBlueColor.CGColor;
            [self startPulseAnimation];
            break;
        case ESCloudKitDotStateSuccess:
            self.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
            break;
        case ESCloudKitDotStateError:
            self.layer.backgroundColor = NSColor.systemRedColor.CGColor;
            break;
    }
}

- (void)startPulseAnimation {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.35;
    pulse.duration = 0.9;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.layer addAnimation:pulse forKey:@"opacityPulse"];
}

- (void)refreshTooltip {
    NSString *stateStr;
    switch (self.state) {
        case ESCloudKitDotStateIdle:    stateStr = @"idle";    break;
        case ESCloudKitDotStateActive:  stateStr = @"active";  break;
        case ESCloudKitDotStateSuccess: stateStr = @"success"; break;
        case ESCloudKitDotStateError:   stateStr = @"error";   break;
    }

    if (self.lastEventDate) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
        self.toolTip = [NSString stringWithFormat:@"%@ — %@ at %@",
                        self.label, stateStr,
                        [fmt stringFromDate:self.lastEventDate]];
    } else {
        self.toolTip = [NSString stringWithFormat:@"%@ — %@", self.label, stateStr];
    }
}

@end

#pragma mark - ViewController

@interface ESSystemPulseViewController () <NSFetchedResultsControllerDelegate, NSPopoverDelegate>
@property (nonatomic, strong) NSView *trafficLight;
@property (nonatomic, strong) NSTextField *serverStatusLabel;
@property (nonatomic, strong) NSTextField *portLabel;
@property (nonatomic, strong) NSTextField *memoryCountLabel;
@property (nonatomic, strong) NSTextField *vectorCountLabel;
@property (nonatomic, strong) NSTextField *cacheSizeLabel;
@property (nonatomic, strong) NSTextField *toolCallCountLabel;
@property (nonatomic, strong) NSTextField *queueDepthLabel;
@property (nonatomic, strong) ESCloudKitDot *ckLinkDot;
@property (nonatomic, strong) ESCloudKitDot *ckImportDot;
@property (nonatomic, strong) ESCloudKitDot *ckExportDot;
@property (nonatomic, strong) NSPopover *activePopover;
@property (nonatomic, strong) NSScrollView *logScrollView;
@property (nonatomic, strong) NSTextView *logTextView;
@property (nonatomic, strong) NSFetchedResultsController *memoryFRC;
@property (nonatomic, strong) NSFetchedResultsController *vectorFRC;
@property (nonatomic, assign) NSUInteger toolCallCount;
@property (nonatomic, assign) BOOL startupLogged;
@property (nonatomic, assign) BOOL cloudKitLinkLogged;
@end

@implementation ESSystemPulseViewController

#pragma mark - Lifecycle

- (void)loadView {
    // Narrower and taller than before — the button row is gone and the log
    // deserves more vertical room.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 440)];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self buildUI];
    [self setupFRCs];
    [self refreshStats];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(toolDidExecute:)
                                                 name:ESToolExecutedNotification
                                               object:nil];

    // CloudKit sync indicators — ESCoreDataStack already observes the same
    // notification for logging; we register a parallel observer to drive
    // the three dots. The event carries the type (Setup/Import/Export),
    // the start/succeeded flags, and the error (if any).
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(cloudKitEventChanged:)
                                                 name:NSPersistentCloudKitContainerEventChangedNotification
                                               object:nil];

    // Surface Core Data / CloudKit errors in the System Pulse log so failures
    // (especially in Release builds where ESLog is stripped) are visible
    // without attaching Console.app.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(coreDataStackErrored:)
                                                 name:ESCoreDataStackErrorNotification
                                               object:nil];

    // Observe the live server port. MCPServer is the single source of truth;
    // NSKeyValueObservingOptionInitial fires once immediately so the indicator
    // gets its first value without a manual refresh.
    [[MCPServer sharedInstance] addObserver:self
                                 forKeyPath:@"boundPortNumber"
                                    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                                    context:kMCPServerPortContext];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    self.memoryFRC.delegate = nil;
    self.vectorFRC.delegate = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[MCPServer sharedInstance] removeObserver:self
                                    forKeyPath:@"boundPortNumber"
                                       context:kMCPServerPortContext];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context == kMCPServerPortContext) {
        [self updateServerStatusUI];
        NSNumber *port = [MCPServer sharedInstance].boundPortNumber;
        if (port && !self.startupLogged) {
            self.startupLogged = YES;
            // KVO may fire on a background queue (GCDWebServer). Dispatch to main
            // so appendStartupLine: reaches the text storage safely.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendStartupSequenceForPort:port];
            });
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

/// Refresh the traffic light, "Running/Stopped" label, and port label to match
/// the current `MCPServer.boundPortNumber`. Shared by the KVO observer and by
/// `-refreshStats` so the indicator stays correct from either path.
- (void)updateServerStatusUI {
    NSNumber *port = [MCPServer sharedInstance].boundPortNumber;
    if (port != nil) {
        self.trafficLight.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
        self.serverStatusLabel.stringValue = @"Running";
        // No single host:port here — the server is multi-port (one listener
        // per persona). Per-listener detail lives in the startup log.
        self.portLabel.stringValue = @"";
    } else {
        self.trafficLight.layer.backgroundColor = NSColor.systemRedColor.CGColor;
        self.serverStatusLabel.stringValue = @"Stopped";
        self.portLabel.stringValue = @"";
    }
}

#pragma mark - UI Construction

- (void)buildUI {
    // --- Header: traffic light + server status ---
    self.trafficLight = [self circleViewWithSize:12];
    self.serverStatusLabel = [self headerLabelWithString:@"Server"];
    self.portLabel = [self captionLabelWithString:@""];

    NSStackView *headerStack = [NSStackView stackViewWithViews:@[
        self.trafficLight, self.serverStatusLabel, self.portLabel
    ]];
    headerStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerStack.alignment = NSLayoutAttributeCenterY;
    headerStack.spacing = 8;

    // --- Stats grid (left-aligned, values in a consistent second column) ---
    self.memoryCountLabel   = [self statValueLabel];
    self.vectorCountLabel   = [self statValueLabel];
    self.cacheSizeLabel     = [self statValueLabel];
    self.toolCallCountLabel = [self statValueLabel];
    self.queueDepthLabel    = [self statValueLabel];

    // CloudKit row — three dots with inline labels.
    NSView *cloudKitRow = [self buildCloudKitRow];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[self statTitleLabel:@"Entries"],   self.memoryCountLabel],
        @[[self statTitleLabel:@"Vectors"],    self.vectorCountLabel],
        @[[self statTitleLabel:@"Cache"],      self.cacheSizeLabel],
        @[[self statTitleLabel:@"Tool Calls"], self.toolCallCountLabel],
        @[[self statTitleLabel:@"Queue"],      self.queueDepthLabel],
        @[[self statTitleLabel:@"CloudKit"],   cloudKitRow],
    ]];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowSpacing = 4;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;

    // --- MCP Tool Calls log ---
    NSTextField *logTitle = [self captionLabelWithString:@"MCP Tool Calls"];
    logTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    logTitle.textColor = NSColor.labelColor;

    self.logTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.logTextView.editable = NO;
    self.logTextView.selectable = YES;
    self.logTextView.richText = NO;
    self.logTextView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.logTextView.textColor = NSColor.secondaryLabelColor;
    self.logTextView.backgroundColor = [NSColor colorWithWhite:0 alpha:0.03];
    self.logTextView.textContainerInset = NSMakeSize(6, 4);
    self.logTextView.verticallyResizable = YES;
    self.logTextView.horizontallyResizable = NO;
    self.logTextView.autoresizingMask = NSViewWidthSizable;
    self.logTextView.textContainer.widthTracksTextView = YES;

    self.logScrollView = [[NSScrollView alloc] init];
    self.logScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logScrollView.documentView = self.logTextView;
    self.logScrollView.hasVerticalScroller = YES;
    self.logScrollView.autohidesScrollers = YES;
    self.logScrollView.borderType = NSLineBorder;

    // --- Main vertical stack ---
    NSStackView *mainStack = [NSStackView stackViewWithViews:@[
        headerStack, [self thinSeparator], grid,
        [self thinSeparator], logTitle, self.logScrollView
    ]];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.alignment = NSLayoutAttributeLeading;
    mainStack.spacing = 10;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);

    [self.view addSubview:mainStack];
    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [mainStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [mainStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [mainStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.logScrollView.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor constant:-40],
        [self.logScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];

    // Let the log expand to fill available space.
    [mainStack setHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationVertical];
    [self.logScrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationVertical];
}

/// Build the CloudKit indicator row: three (dot + label) pairs in a horizontal
/// stack. Each dot has a click recognizer that opens a detail popover.
- (NSView *)buildCloudKitRow {
    self.ckLinkDot   = [self makeDotWithLabel:@"Setup"  isLink:YES];
    self.ckImportDot = [self makeDotWithLabel:@"Import" isLink:NO];
    self.ckExportDot = [self makeDotWithLabel:@"Export" isLink:NO];

    NSStackView *row = [NSStackView stackViewWithViews:@[
        self.ckLinkDot,   [self ckCaptionLabel:@"Link"],
        self.ckImportDot, [self ckCaptionLabel:@"↓ In"],
        self.ckExportDot, [self ckCaptionLabel:@"↑ Out"],
    ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 4;
    [row setCustomSpacing:10 afterView:[row.views objectAtIndex:1]];
    [row setCustomSpacing:10 afterView:[row.views objectAtIndex:3]];
    return row;
}

- (ESCloudKitDot *)makeDotWithLabel:(NSString *)label isLink:(BOOL)isLink {
    ESCloudKitDot *dot = [[ESCloudKitDot alloc] init];
    dot.label = label;
    dot.isLink = isLink;
    [dot refreshTooltip];

    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc]
        initWithTarget:self action:@selector(cloudKitDotClicked:)];
    [dot addGestureRecognizer:click];
    return dot;
}

- (NSTextField *)ckCaptionLabel:(NSString *)text {
    NSTextField *tf = [NSTextField labelWithString:text];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tf.textColor = NSColor.secondaryLabelColor;
    return tf;
}

#pragma mark - FRC Setup

- (void)setupFRCs {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;

    // Memory FRC — counting only, no property values loaded.
    NSFetchRequest *memFetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    memFetch.includesSubentities = NO;
    memFetch.includesPropertyValues = NO;
    memFetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:NO]];
    self.memoryFRC = [[NSFetchedResultsController alloc] initWithFetchRequest:memFetch
                                                         managedObjectContext:ctx
                                                           sectionNameKeyPath:nil
                                                                    cacheName:nil];
    self.memoryFRC.delegate = self;
    [self.memoryFRC performFetch:nil];

    // Vector FRC — counting only, no property values loaded.
    NSFetchRequest *vecFetch = [NSFetchRequest fetchRequestWithEntityName:@"CDVector"];
    vecFetch.includesPropertyValues = NO;
    vecFetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:NO]];
    self.vectorFRC = [[NSFetchedResultsController alloc] initWithFetchRequest:vecFetch
                                                         managedObjectContext:ctx
                                                           sectionNameKeyPath:nil
                                                                    cacheName:nil];
    self.vectorFRC.delegate = self;
    [self.vectorFRC performFetch:nil];
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshStats) object:nil];
    [self performSelector:@selector(refreshStats) withObject:nil afterDelay:0];
}

#pragma mark - Stats Refresh

- (void)refreshStats {
    [self updateServerStatusUI];

    NSUInteger memCount = self.memoryFRC.fetchedObjects.count;
    self.memoryCountLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)memCount];

    NSUInteger vecCount = self.vectorFRC.fetchedObjects.count;
    self.vectorCountLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)vecCount];

    // Cache footprint is a pure function of the vector count and the active
    // embedder's dimension — derive it from the count shown above rather than
    // from the in-memory cache, which warms asynchronously after this view's
    // first refresh (loading vectors into memory fires no Core Data change,
    // so an FRC-driven refresh never re-read it — the label stuck at 0.00).
    // Computing from vecCount is correct from launch and updates whenever the
    // count does.
    NSUInteger dim = [ESVectorEngine summaryEmbedder].vectorDimension;
    double cacheMB = (double)(vecCount * dim * sizeof(float)) / (1024.0 * 1024.0);
    self.cacheSizeLabel.stringValue = [NSString stringWithFormat:@"%.2f MB", cacheMB];

    self.toolCallCountLabel.stringValue = [NSString stringWithFormat:@"%lu",
        (unsigned long)self.toolCallCount];

    NSUInteger pending = [[ESVectorEngine shared] pendingVectorOperations];
    self.queueDepthLabel.stringValue = pending > 0
        ? [NSString stringWithFormat:@"%lu pending", (unsigned long)pending]
        : @"idle";
}

#pragma mark - CloudKit Events

- (void)cloudKitEventChanged:(NSNotification *)note {
    NSPersistentCloudKitContainerEvent *event =
        note.userInfo[NSPersistentCloudKitContainerEventUserInfoKey];
    if (!event) return;

    // The Link dot's original signal — the one-shot Setup event — fires once,
    // early, and the dashboard is usually opened lazily long after, so it's
    // routinely missed and the dot stays gray. But a successful Import or
    // Export is itself proof the CloudKit link is live: drive Link green off
    // any sync success, not just Setup. isLink dots hold green (no fade), so
    // one successful round-trip lights it and it stays lit.
    if (event.succeeded && !event.error &&
        (event.type == NSPersistentCloudKitContainerEventTypeImport ||
         event.type == NSPersistentCloudKitContainerEventTypeExport)) {
        NSDate *ts = event.endDate ?: event.startDate ?: [NSDate now];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.ckLinkDot applyState:ESCloudKitDotStateSuccess timestamp:ts error:nil];
            if (!self.cloudKitLinkLogged) {
                self.cloudKitLinkLogged = YES;
                [self appendStartupLine:@"CloudKit link active"];
            }
        });
    }

    ESCloudKitDot *dot = nil;
    switch (event.type) {
        case NSPersistentCloudKitContainerEventTypeSetup:  dot = self.ckLinkDot;   break;
        case NSPersistentCloudKitContainerEventTypeImport: dot = self.ckImportDot; break;
        case NSPersistentCloudKitContainerEventTypeExport: dot = self.ckExportDot; break;
    }
    if (!dot) return;

    ESCloudKitDotState state;
    if (event.error) {
        state = ESCloudKitDotStateError;
    } else if (event.succeeded) {
        state = ESCloudKitDotStateSuccess;
    } else {
        state = ESCloudKitDotStateActive;
    }

    // NSPersistentCloudKitContainerEvent notifications can arrive off the
    // main queue; dot UI must be updated on main.
    dispatch_async(dispatch_get_main_queue(), ^{
        [dot applyState:state timestamp:(event.endDate ?: event.startDate ?: [NSDate now])
                  error:event.error];

        if (event.type == NSPersistentCloudKitContainerEventTypeSetup
                && event.succeeded && !self.cloudKitLinkLogged) {
            self.cloudKitLinkLogged = YES;
            [self appendStartupLine:@"CloudKit link active"];
        }
    });
}

- (void)cloudKitDotClicked:(NSClickGestureRecognizer *)sender {
    if (![sender.view isKindOfClass:[ESCloudKitDot class]]) return;
    ESCloudKitDot *dot = (ESCloudKitDot *)sender.view;
    [self presentDetailPopoverForDot:dot];
}

- (void)presentDetailPopoverForDot:(ESCloudKitDot *)dot {
    [self.activePopover performClose:nil];

    NSString *stateStr;
    switch (dot.state) {
        case ESCloudKitDotStateIdle:    stateStr = @"Idle";    break;
        case ESCloudKitDotStateActive:  stateStr = @"Active";  break;
        case ESCloudKitDotStateSuccess: stateStr = @"Success"; break;
        case ESCloudKitDotStateError:   stateStr = @"Error";   break;
    }

    NSMutableString *body = [NSMutableString stringWithFormat:@"%@\nState: %@\n",
                             dot.label, stateStr];
    if (dot.lastEventDate) {
        NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
        [body appendFormat:@"Last event: %@\n", [iso stringFromDate:dot.lastEventDate]];
    }
    if (dot.lastError) {
        [body appendFormat:@"\nError domain: %@\nCode: %ld\n%@",
         dot.lastError.domain,
         (long)dot.lastError.code,
         dot.lastError.localizedDescription ?: @""];
    }

    NSTextField *label = [NSTextField wrappingLabelWithString:body];
    label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.translatesAutoresizingMaskIntoConstraints = NO;

    NSViewController *content = [[NSViewController alloc] init];
    content.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 80)];
    [content.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:content.view.topAnchor constant:12],
        [label.bottomAnchor constraintEqualToAnchor:content.view.bottomAnchor constant:-12],
        [label.leadingAnchor constraintEqualToAnchor:content.view.leadingAnchor constant:12],
        [label.trailingAnchor constraintEqualToAnchor:content.view.trailingAnchor constant:-12],
        [content.view.widthAnchor constraintEqualToConstant:400],
    ]];

    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = content;
    popover.delegate = self;
    self.activePopover = popover;
    [popover showRelativeToRect:dot.bounds ofView:dot preferredEdge:NSRectEdgeMaxY];
}

- (void)popoverDidClose:(NSNotification *)notification {
    if (notification.object == self.activePopover) {
        self.activePopover = nil;
    }
}

#pragma mark - Startup Log

- (void)appendStartupSequenceForPort:(NSNumber *)port {
    NSUInteger vecCount = self.vectorFRC.fetchedObjects.count;
    NSUInteger memCount = self.memoryFRC.fetchedObjects.count;

    NSMutableArray<NSString *> *lines = [@[
        @"MCP interface ready",
        [NSString stringWithFormat:@"Vector store loaded: %lu vectors",   (unsigned long)vecCount],
        [NSString stringWithFormat:@"Archive loaded: %lu entries", (unsigned long)memCount],
    ] mutableCopy];

    // One "listening" line per bound persona port — the server is multi-port.
    NSArray<NSDictionary *> *bindings = [MCPServer sharedInstance].activeBindings;
    if (bindings.count == 0) {
        [lines addObject:[NSString stringWithFormat:@"Server listening on localhost:%@", port]];
    } else {
        for (NSDictionary *b in bindings) {
            NSString *jwt = [b[@"jwt"] boolValue] ? @" (JWT)" : @"";
            [lines addObject:[NSString stringWithFormat:@"Listening on localhost:%@ — %@%@",
                              b[@"port"], b[@"author"], jwt]];
        }
    }
    [lines addObject:@"Ready for MCP client connection"];

    NSTimeInterval delay = 0;
    for (NSString *line in lines) {
        [self performSelector:@selector(appendStartupLine:) withObject:line afterDelay:delay];
        delay += 0.07;
    }
}

- (void)coreDataStackErrored:(NSNotification *)note {
    NSString *msg = note.userInfo[@"message"];
    if (msg.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendErrorLine:msg];
    });
}

/// Append a single error log line in red. Used for Core Data / CloudKit
/// failures that the user needs to see without opening Console.app.
- (void)appendErrorLine:(NSString *)text {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [fmt stringFromDate:[NSDate now]], text];

    BOOL wasAtBottom = [self logIsScrolledToBottom];
    [self.logTextView.textStorage appendAttributedString:
        [[NSAttributedString alloc] initWithString:line
            attributes:@{
                NSFontAttributeName:            [NSFont monospacedSystemFontOfSize:10
                                                                            weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: NSColor.systemRedColor,
            }]];
    [self trimLogToMaxLines:kLogMaxLines];
    if (wasAtBottom) [self.logTextView scrollToEndOfDocument:nil];
}

/// Append a single startup/system log line in the primary label colour,
/// visually distinct from the dimmer tool-call entries.
- (void)appendStartupLine:(NSString *)text {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [fmt stringFromDate:[NSDate now]], text];

    BOOL wasAtBottom = [self logIsScrolledToBottom];
    [self.logTextView.textStorage appendAttributedString:
        [[NSAttributedString alloc] initWithString:line
            attributes:@{
                NSFontAttributeName:            [NSFont monospacedSystemFontOfSize:10
                                                                            weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: NSColor.labelColor,
            }]];
    [self trimLogToMaxLines:kLogMaxLines];
    if (wasAtBottom) [self.logTextView scrollToEndOfDocument:nil];
}

#pragma mark - Tool Execution Log

- (void)toolDidExecute:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.toolCallCount++;
        [self refreshStats];
        [self appendToolCallLineFromNote:note];
    });
}

- (void)appendToolCallLineFromNote:(NSNotification *)note {
    NSString *tool       = note.userInfo[@"tool"] ?: @"unknown";
    NSDictionary *args   = note.userInfo[@"arguments"] ?: @{};
    NSDictionary *result = note.userInfo[@"result"]    ?: @{};

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *ts = [fmt stringFromDate:[NSDate now]];

    NSString *paddedTool = [tool stringByPaddingToLength:kToolNameColumnWidth
                                              withString:@" "
                                         startingAtIndex:0];
    NSString *arg   = [self identifyingArgForTool:tool arguments:args];
    NSString *shape = [self resultShapeForTool:tool result:result];

    NSString *line;
    if (arg.length) {
        line = [NSString stringWithFormat:@"[%@] %@ \"%@\" %@\n",
                ts, paddedTool, arg, shape];
    } else {
        line = [NSString stringWithFormat:@"[%@] %@ %@\n", ts, paddedTool, shape];
    }

    BOOL wasAtBottom = [self logIsScrolledToBottom];
    [self.logTextView.textStorage appendAttributedString:
        [[NSAttributedString alloc] initWithString:line
            attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
            }]];
    [self trimLogToMaxLines:kLogMaxLines];
    if (wasAtBottom) {
        [self.logTextView scrollToEndOfDocument:nil];
    }
}

/// Return the most identifying argument for the given tool, truncated to
/// `kArgMaxChars` with an ellipsis if longer. Returns `nil` for tools that
/// have no single identifying argument (archive_timeline, archive_discover, etc.).
- (nullable NSString *)identifyingArgForTool:(NSString *)tool
                                    arguments:(NSDictionary *)args {
    static NSDictionary<NSString *, NSString *> *keyMap;
    static NSSet<NSString *> *omit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keyMap = @{
            @"archive_search"             : @"query",
            @"archive_grep"               : @"pattern",
            @"archive_read"               : @"title",
            @"archive_update"             : @"title",
            @"archive_erase"              : @"title",
            @"archive_tagged"             : @"tag",
            @"archive_tag"                : @"title",
            @"archive_untag"              : @"title",
            @"archive_link"               : @"title",
            @"archive_add_comment"        : @"title",
            @"archive_remove_comment"     : @"title",
            @"archive_add_attachment"     : @"title",
            @"archive_remove_attachment"  : @"title",
            @"archive_recall_attachment"  : @"title",
        };
        omit = [NSSet setWithArray:@[
            @"archive_timeline", @"archive_discover",
            @"archive_tags",   @"archive_links",
            @"archive_author_list",
        ]];
    });

    if ([omit containsObject:tool]) return nil;

    NSString *raw = nil;
    if ([tool isEqualToString:@"archive_store"]) {
        // For stores, the identifying value is the title — i.e. the body's
        // first line before a newline.
        NSString *body = [args[@"body"] isKindOfClass:[NSString class]] ? args[@"body"] : nil;
        raw = [[body componentsSeparatedByString:@"\n"] firstObject];
    } else {
        NSString *key = keyMap[tool];
        if (!key) return nil;
        id value = args[key];
        if ([value isKindOfClass:[NSString class]]) raw = (NSString *)value;
    }

    if (raw.length == 0) return nil;
    if (raw.length > kArgMaxChars) {
        return [[raw substringToIndex:kArgMaxChars - 1] stringByAppendingString:@"…"];
    }
    return raw;
}

/// Glyph + short label reflecting what the tool returned. Priority order is
/// documented in the plan; status wins, then tool-specific, then list shapes,
/// then single-entity fallback.
- (NSString *)resultShapeForTool:(NSString *)tool result:(NSDictionary *)result {
    NSString *status = [result[@"status"] isKindOfClass:[NSString class]] ? result[@"status"] : nil;

    if ([status isEqualToString:@"error"])     return @"✗ error";
    if ([status isEqualToString:@"not_found"]) return @"✗ not found";
    if ([status isEqualToString:@"ambiguous"]) return @"✗ ambiguous";
    if ([status isEqualToString:@"created"])   return @"✓ stored";
    if ([status isEqualToString:@"updated"])   return @"✓ updated";
    if ([status isEqualToString:@"erased"])    return @"✓ erased";

    if ([tool isEqualToString:@"archive_grep"]) {
        NSNumber *count = result[@"match_count"];
        if (![count isKindOfClass:[NSNumber class]]) {
            NSArray *r = result[@"results"];
            count = @([r isKindOfClass:[NSArray class]] ? r.count : 0);
        }
        return [NSString stringWithFormat:@"→ %lu %@",
                (unsigned long)count.unsignedIntegerValue,
                count.unsignedIntegerValue == 1 ? @"hit" : @"hits"];
    }

    NSArray *results = result[@"results"];
    if ([results isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"⊕ %lu", (unsigned long)results.count];
    }
    NSArray *tags = result[@"tags"];
    if ([tags isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"⊕ %lu", (unsigned long)tags.count];
    }
    NSArray *references = result[@"references"];
    if ([references isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"⊕ %lu", (unsigned long)references.count];
    }

    // Single-entity success (archive_read, archive_reference single mode).
    return @"✓";
}

#pragma mark - Log Mechanics

- (BOOL)logIsScrolledToBottom {
    NSScrollView *sv = self.logScrollView;
    CGFloat visibleMax = NSMaxY(sv.contentView.bounds);
    CGFloat contentMax = NSMaxY(self.logTextView.frame);
    return (contentMax - visibleMax) <= 8.0;
}

- (void)trimLogToMaxLines:(NSUInteger)maxLines {
    NSTextStorage *storage = self.logTextView.textStorage;
    NSString *s = storage.string;
    NSUInteger total = [[s componentsSeparatedByString:@"\n"] count] - 1; // trailing empty
    if (total <= maxLines) return;

    // Find the cutoff newline — walk from the front until we've left
    // exactly `maxLines` entries behind.
    NSUInteger toRemove = total - maxLines;
    NSRange searchRange = NSMakeRange(0, s.length);
    NSUInteger cutoff = 0;
    for (NSUInteger i = 0; i < toRemove; i++) {
        NSRange nl = [s rangeOfString:@"\n" options:0 range:searchRange];
        if (nl.location == NSNotFound) return;
        cutoff = nl.location + nl.length;
        searchRange = NSMakeRange(cutoff, s.length - cutoff);
    }
    [storage deleteCharactersInRange:NSMakeRange(0, cutoff)];
}

#pragma mark - UI Factories

- (NSView *)circleViewWithSize:(CGFloat)size {
    NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size, size)];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = size / 2.0;
    dot.layer.backgroundColor = NSColor.systemGrayColor.CGColor;
    [NSLayoutConstraint activateConstraints:@[
        [dot.widthAnchor constraintEqualToConstant:size],
        [dot.heightAnchor constraintEqualToConstant:size],
    ]];
    return dot;
}

- (NSTextField *)headerLabelWithString:(NSString *)string {
    NSTextField *tf = [NSTextField labelWithString:string];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    return tf;
}

- (NSTextField *)captionLabelWithString:(NSString *)string {
    NSTextField *tf = [NSTextField labelWithString:string];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tf.textColor = NSColor.secondaryLabelColor;
    return tf;
}

- (NSTextField *)statTitleLabel:(NSString *)title {
    NSTextField *tf = [NSTextField labelWithString:title];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    tf.textColor = NSColor.secondaryLabelColor;
    tf.alignment = NSTextAlignmentRight;
    return tf;
}

- (NSTextField *)statValueLabel {
    NSTextField *tf = [NSTextField labelWithString:@"--"];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
    return tf;
}

- (NSBox *)thinSeparator {
    NSBox *sep = [[NSBox alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.boxType = NSBoxSeparator;
    return sep;
}

@end
