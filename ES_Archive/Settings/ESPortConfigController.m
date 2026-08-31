//
//  ESPortConfigController.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESPortConfigController.h"
#import "ESAuthorConfigController.h"
#import "ESServerConfig.h"
#import "MCPServer.h"
#import "NSViewController+ESUIHelpers.h"

static NSString * const kColPort   = @"port";
static NSString * const kColAuthor = @"author";
static NSString * const kColJWT    = @"jwt"; // per-route Cf-Access requirement

@interface ESPortConfigController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *bridgeCheckbox;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong) NSButton *applyButton;
@property (nonatomic, strong) NSTextField *statusLabel;

/// The persona the bridge port serves, when one was stored explicitly.
/// nil means "the default" — Apply then leaves the entry to the read-time
/// injection in ESServerConfig rather than pinning an author here.
@property (nonatomic, copy, nullable) NSString *bridgeAuthor;

/// One row per binding. Each is a mutable
/// {port: NSNumber, author: NSString, jwt: NSNumber(BOOL)}.
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *rows;

/// Popup choices for the author column — the archive's known personas, plus
/// any bound author that isn't in that list (so old bindings stay visible).
@property (nonatomic, strong) NSArray<NSString *> *authorChoices;
@end

@implementation ESPortConfigController

- (void)loadView {
    self.title = @"Ports";

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 380)];

    NSTextField *heading = [self es_labelWithString:@"Ports"];
    heading.font = [NSFont boldSystemFontOfSize:13];

    NSTextField *blurb = [self es_labelWithString:
        @"Each row binds a listening port to a persona. The port a request "
        @"arrives on sets its identity, so authorship is stamped from the "
        @"channel, never asserted by the client. Personas themselves are "
        @"managed on the Personas pane. Changes apply on relaunch."];
    blurb.font = [NSFont systemFontOfSize:11];
    blurb.textColor = NSColor.secondaryLabelColor;
    blurb.lineBreakMode = NSLineBreakByWordWrapping;
    blurb.maximumNumberOfLines = 0;
    blurb.preferredMaxLayoutWidth = 480; // wrap rather than stretch the window

    // The Claude bridge is a fixed line, not a table row: its port never
    // changes (the .mcpb bridge hardcodes it), it can only be switched
    // on or off.
    NSButton *bridge = [NSButton checkboxWithTitle:@"" target:self action:@selector(bridgeToggled:)];
    bridge.toolTip = @"Serve the Claude bridge (ES-Archive-MCP.mcpb) on its fixed port. "
                     @"The port stays reserved for the bridge even while it is off.";
    self.bridgeCheckbox = bridge;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] init];
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsMultipleSelection = NO;
    table.dataSource = self;
    table.delegate = self;
    // NSTextFieldCell top-aligns its text, so a row taller than the font's
    // line height leaves all the slack below the baseline and the text reads
    // as off-center. Size the row to the cell font instead.
    NSFont *cellFont = [NSFont systemFontOfSize:NSFont.systemFontSize];
    table.rowHeight = ceil(cellFont.boundingRectForFont.size.height) + 2;

    NSTableColumn *portCol = [[NSTableColumn alloc] initWithIdentifier:kColPort];
    portCol.title = @"Port";
    portCol.width = 80;
    portCol.minWidth = 70;
    NSTextFieldCell *portCell = [[NSTextFieldCell alloc] init];
    portCell.editable = YES;
    portCell.font = cellFont;
    NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    fmt.allowsFloats = NO;
    fmt.maximumFractionDigits = 0;
    fmt.usesGroupingSeparator = NO;
    portCell.formatter = fmt;
    portCol.dataCell = portCell;
    [table addTableColumn:portCol];

    NSTableColumn *authorCol = [[NSTableColumn alloc] initWithIdentifier:kColAuthor];
    authorCol.title = @"Persona (author)";
    authorCol.width = 240;
    authorCol.minWidth = 150;
    NSPopUpButtonCell *authorCell = [[NSPopUpButtonCell alloc] init];
    authorCell.bordered = NO;
    authorCell.controlSize = NSControlSizeSmall;
    authorCell.font = [NSFont systemFontOfSize:11];
    authorCol.dataCell = authorCell;
    [table addTableColumn:authorCol];

    NSTableColumn *jwtCol = [[NSTableColumn alloc] initWithIdentifier:kColJWT];
    jwtCol.title = @"Require JWT";
    jwtCol.width = 90;
    jwtCol.minWidth = 80;
    NSButtonCell *jwtCell = [[NSButtonCell alloc] init];
    [jwtCell setButtonType:NSButtonTypeSwitch];
    jwtCell.title = @"";
    jwtCol.dataCell = jwtCell;
    [table addTableColumn:jwtCol];

    scroll.documentView = table;
    self.tableView = table;

    NSButton *addButton = [NSButton buttonWithTitle:@"+" target:self action:@selector(addRow:)];
    addButton.bezelStyle = NSBezelStyleRounded;
    addButton.toolTip = @"Bind a persona to a new port";
    NSButton *removeButton = [NSButton buttonWithTitle:@"–" target:self action:@selector(removeRow:)];
    removeButton.bezelStyle = NSBezelStyleRounded;
    removeButton.toolTip = @"Unbind this port. The persona and its records are untouched.";
    self.removeButton = removeButton;
    NSStackView *rowButtons = [NSStackView stackViewWithViews:@[addButton, removeButton]];
    rowButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowButtons.spacing = 6;

    self.statusLabel = [self es_labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = NSColor.systemRedColor;

    NSButton *apply = [NSButton buttonWithTitle:@"Apply & Relaunch" target:self action:@selector(apply:)];
    apply.bezelStyle = NSBezelStyleRounded;
    apply.keyEquivalent = @"\r";
    self.applyButton = apply;

    NSStackView *bottom = [NSStackView stackViewWithViews:@[self.statusLabel, apply]];
    bottom.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottom.distribution = NSStackViewDistributionFill;
    [self.statusLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSArray<NSView *> *all = @[heading, blurb, bridge, scroll, rowButtons, bottom];
    for (NSView *v in all) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }

    CGFloat m = 20;
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:520],

        [heading.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [heading.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [heading.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [blurb.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:6],
        [blurb.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [blurb.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [bridge.topAnchor constraintEqualToAnchor:blurb.bottomAnchor constant:12],
        [bridge.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [bridge.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],

        [scroll.topAnchor constraintEqualToAnchor:bridge.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [scroll.heightAnchor constraintEqualToConstant:190],

        [rowButtons.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:6],
        [rowButtons.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [bottom.topAnchor constraintEqualToAnchor:rowButtons.bottomAnchor constant:16],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [bottom.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
    ]];

    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self reloadRows];
    [self updateState];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    // Personas may have been created/renamed/merged on the other pane since
    // this view was last shown — rebuild rows and the popup choices.
    [self reloadRows];
    [self updateState];
}

#pragma mark - Data load

/// One row per bound port, sorted by port. The author popup offers every known
/// persona so bindings always pick a canonical spelling. The Claude bridge's
/// fixed port is represented by the checkbox line, never as a row.
- (void)reloadRows {
    NSDictionary<NSNumber *, NSString *> *map = [ESServerConfig portAuthorMap];

    NSMutableArray<NSString *> *choices = [[ESAuthorConfigController allKnownAuthors] mutableCopy];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:choices];

    NSMutableArray<NSMutableDictionary *> *rows = [NSMutableArray array];
    NSArray<NSNumber *> *ports = [map.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *p in ports) {
        if (p.integerValue == ESServerDefaultPort) continue; // the bridge line
        NSString *a = map[p];
        if (![seen containsObject:a]) { [choices addObject:a]; [seen addObject:a]; }
        BOOL jwt = [ESServerConfig requiresJWTForPort:(UInt16)p.integerValue];
        [rows addObject:[@{kColPort: p, kColAuthor: a, kColJWT: @(jwt)} mutableCopy]];
    }

    self.authorChoices = choices;
    self.rows = rows;

    // Populate the author column's prototype cell BEFORE reloading: each row
    // cell is stamped from it with the menu already in place, so the index
    // object value selects the right item. (Rebuilding the menu per row in
    // -tableView:willDisplayCell:… is too late — the object value is applied
    // first, and removeAllItems resets every popup to item 0.)
    NSPopUpButtonCell *authorCell =
        (NSPopUpButtonCell *)[self.tableView tableColumnWithIdentifier:kColAuthor].dataCell;
    [authorCell removeAllItems];
    [authorCell addItemsWithTitles:choices];

    [self.tableView reloadData];

    BOOL bridgeOn = [ESServerConfig claudeBridgeEnabled];
    self.bridgeAuthor = [ESServerConfig authorForPort:ESServerDefaultPort]; // nil while off
    self.bridgeCheckbox.state = bridgeOn ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *served = bridgeOn && self.bridgeAuthor
        ? [NSString stringWithFormat:@" — serves “%@”", self.bridgeAuthor] : @"";
    self.bridgeCheckbox.title = [NSString stringWithFormat:
        @"Claude bridge on port %u%@", ESServerDefaultPort, served];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.rows.count;
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) return nil;
    NSDictionary *r = self.rows[row];
    if ([tableColumn.identifier isEqualToString:kColPort]) {
        NSInteger p = [r[kColPort] integerValue];
        return p > 0 ? @(p) : nil;
    }
    if ([tableColumn.identifier isEqualToString:kColJWT]) {
        return @([r[kColJWT] boolValue] ? NSControlStateValueOn : NSControlStateValueOff);
    }
    // Popup cells take the selected item's index as their object value.
    NSUInteger idx = [self.authorChoices indexOfObject:r[kColAuthor]];
    return @(idx == NSNotFound ? 0 : idx);
}

- (void)tableView:(NSTableView *)tableView
   setObjectValue:(id)object
   forTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.rows.count) return;
    if ([tableColumn.identifier isEqualToString:kColPort]) {
        NSInteger p = [object respondsToSelector:@selector(integerValue)] ? [object integerValue] : 0;
        self.rows[row][kColPort] = @(p > 0 ? p : 0);
    } else if ([tableColumn.identifier isEqualToString:kColJWT]) {
        self.rows[row][kColJWT] = @([object integerValue] != NSControlStateValueOff);
    } else {
        NSInteger idx = [object respondsToSelector:@selector(integerValue)] ? [object integerValue] : -1;
        if (idx >= 0 && idx < (NSInteger)self.authorChoices.count) {
            self.rows[row][kColAuthor] = self.authorChoices[idx];
        }
    }
    [self updateState];
}

#pragma mark - NSTableViewDelegate

- (BOOL)tableView:(NSTableView *)tableView
shouldEditTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row {
    return YES;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateState];
}

#pragma mark - Actions

- (void)bridgeToggled:(id)sender {
    [self updateState];
}

- (void)addRow:(id)sender {
    if (self.authorChoices.count == 0) {
        self.statusLabel.textColor = NSColor.systemRedColor;
        self.statusLabel.stringValue = @"Create a persona on the Personas pane first.";
        return;
    }
    NSMutableDictionary *r = [@{kColPort: @([self nextFreePort]),
                                kColAuthor: self.authorChoices.firstObject,
                                kColJWT: @NO} mutableCopy];
    [self.rows addObject:r];
    [self.tableView reloadData];
    NSInteger idx = self.rows.count - 1;
    [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
    [self.tableView scrollRowToVisible:idx];
    [self updateState];
}

- (void)removeRow:(id)sender {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return;
    [self.rows removeObjectAtIndex:idx];
    [self.tableView reloadData];
    [self updateState];
}

- (UInt16)nextFreePort {
    // The bridge port is always taken — reserved even while the bridge is off.
    NSMutableSet<NSNumber *> *used = [NSMutableSet setWithObject:@(ESServerDefaultPort)];
    for (NSDictionary *r in self.rows) {
        NSInteger p = [r[kColPort] integerValue];
        if (p > 0) [used addObject:@(p)];
    }
    UInt16 p = ESServerDefaultPort;
    while ([used containsObject:@(p)] && p < 65535) p++;
    return p;
}

#pragma mark - Validation

/// Returns nil when valid, else a human-readable reason.
- (nullable NSString *)validationError {
    NSMutableSet<NSNumber *> *ports = [NSMutableSet set];
    for (NSDictionary *r in self.rows) {
        NSInteger p = [r[kColPort] integerValue];
        if (p < 1024 || p > 65535) return @"Ports must be between 1024 and 65535.";
        if (p == ESServerDefaultPort) return [NSString stringWithFormat:
            @"Port %u is reserved for the Claude bridge.", ESServerDefaultPort];
        if ([ports containsObject:@(p)]) return [NSString stringWithFormat:@"Port %ld is used twice.", (long)p];
        [ports addObject:@(p)];
        if ([r[kColAuthor] length] == 0) return @"Every port needs a persona.";
    }
    return nil;
}

- (void)updateState {
    NSString *err = [self validationError];
    self.statusLabel.textColor = err ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = err ?: @"";
    self.applyButton.enabled = (err == nil);
    self.removeButton.enabled = (self.tableView.selectedRow >= 0);
}

- (void)apply:(id)sender {
    [self.view.window makeFirstResponder:self.tableView]; // commit in-progress edit
    if ([self validationError]) { [self updateState]; return; }

    NSMutableDictionary<NSNumber *, NSString *> *map = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *jwt = [NSMutableDictionary dictionary];
    for (NSDictionary *r in self.rows) {
        NSInteger p = [r[kColPort] integerValue];
        if (p <= 0) continue;
        map[@(p)] = r[kColAuthor];
        jwt[@(p)] = @([r[kColJWT] boolValue]);
    }
    // The bridge line: persist the switch, and keep whatever author the bridge
    // port already had (when none is stored, read-time injection supplies the
    // default). Its JWT flag stays out of the per-port map → global default.
    [ESServerConfig setClaudeBridgeEnabled:
        (self.bridgeCheckbox.state == NSControlStateValueOn)];
    if (self.bridgeAuthor.length > 0) {
        map[@(ESServerDefaultPort)] = self.bridgeAuthor;
    }
    [ESServerConfig setPortAuthorMap:map];
    [ESServerConfig setPortJWTMap:jwt];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self promptRelaunch];
}

#pragma mark - Relaunch

- (void)promptRelaunch {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = @"Relaunch required";
    a.informativeText = @"The port-binding changes take effect after ES Archive relaunches.";
    [a addButtonWithTitle:@"Quit & Reopen"];
    [a addButtonWithTitle:@"Later"];
    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) [self es_relaunchApplication];
    };
    if (parent) [a beginSheetModalForWindow:parent completionHandler:handle];
    else handle([a runModal]);
}

@end
