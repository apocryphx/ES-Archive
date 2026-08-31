//
//  ESStdioPersonaController.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESStdioPersonaController.h"
#import "ESCoreDataStack.h"
#import "ESTagJanitor.h"
#import "NSViewController+ESUIHelpers.h"

static NSString * const kColAuthor = @"author";
static NSString * const kColCount  = @"count";   // records a delete/merge would touch

@interface ESStdioPersonaController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSButton *mergeButton;
@property (nonatomic, strong) NSTextField *statusLabel;

/// One row per persona: {author: NSString, count: NSNumber}.
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@end

@implementation ESStdioPersonaController

#pragma mark - Author list

/// Every distinct, non-empty author currently stamped on a memory. Unlike the
/// HTTP pane there is no declared-authors list or port map to fold in — a
/// persona over the socket exists exactly as long as it has records.
- (NSArray<NSString *> *)distinctArchiveAuthors {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    request.propertiesToFetch = @[kColAuthor];
    request.resultType = NSDictionaryResultType;
    request.returnsDistinctResults = YES;
    request.includesSubentities = NO;

    NSArray *results = [ctx executeFetchRequest:request error:nil] ?: @[];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *row in results) {
        NSString *name = row[kColAuthor];
        if (name.length > 0 && ![seen containsObject:name]) {
            [seen addObject:name];
            [list addObject:name];
        }
    }
    [list sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return list;
}

/// Records a delete/merge would touch, per author: memories (incl. revision
/// subentities), comments, and attachments — exactly the entities the delete
/// and re-stamp passes walk, so the column is an honest blast-radius preview.
- (NSDictionary<NSString *, NSNumber *> *)affectedCountsByAuthor {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSMutableDictionary<NSString *, NSNumber *> *acc = [NSMutableDictionary dictionary];

    NSExpressionDescription *countDesc = [[NSExpressionDescription alloc] init];
    countDesc.name = @"cnt";
    countDesc.expression = [NSExpression expressionForFunction:@"count:"
                                                     arguments:@[[NSExpression expressionForKeyPath:kColAuthor]]];
    countDesc.expressionResultType = NSInteger64AttributeType;

    for (NSString *entity in @[@"CDMemory", @"CDMarginalia", @"CDReference"]) {
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:entity];
        r.resultType = NSDictionaryResultType;
        r.propertiesToFetch = @[kColAuthor, countDesc];
        r.propertiesToGroupBy = @[kColAuthor];
        NSArray *res = [ctx executeFetchRequest:r error:nil] ?: @[];
        for (NSDictionary *row in res) {
            NSString *a = row[kColAuthor];
            if (a.length == 0) continue;
            NSInteger c = [row[@"cnt"] integerValue];
            acc[a] = @([acc[a] integerValue] + c);
        }
    }
    return acc;
}

#pragma mark - View

- (void)loadView {
    self.title = @"Personas";

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 340)];

    NSTextField *heading = [self es_labelWithString:@"Personas"];
    heading.font = [NSFont boldSystemFontOfSize:13];

    NSTextField *blurb = [self es_labelWithString:
        @"Every author in the archive is a persona. Sessions declare their "
        @"persona per connection (--author), so there is nothing to create or "
        @"bind here — only housekeeping: – deletes a persona together with all "
        @"of its records, and Merge… folds its records into another persona."];
    blurb.font = [NSFont systemFontOfSize:11];
    blurb.textColor = NSColor.secondaryLabelColor;
    blurb.lineBreakMode = NSLineBreakByWordWrapping;
    blurb.maximumNumberOfLines = 0;
    blurb.preferredMaxLayoutWidth = 420;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] init];
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsMultipleSelection = NO;
    table.dataSource = self;
    table.delegate = self;
    NSFont *cellFont = [NSFont systemFontOfSize:NSFont.systemFontSize];
    table.rowHeight = ceil(cellFont.boundingRectForFont.size.height) + 2;

    NSTableColumn *authorCol = [[NSTableColumn alloc] initWithIdentifier:kColAuthor];
    authorCol.title = @"Persona (author)";
    authorCol.width = 300;
    authorCol.minWidth = 150;
    NSTextFieldCell *authorCell = [[NSTextFieldCell alloc] init];
    authorCell.editable = NO;
    authorCell.font = cellFont;
    authorCol.dataCell = authorCell;
    [table addTableColumn:authorCol];

    NSTableColumn *countCol = [[NSTableColumn alloc] initWithIdentifier:kColCount];
    countCol.title = @"Records";
    countCol.width = 70;
    countCol.minWidth = 60;
    NSTextFieldCell *countCell = [[NSTextFieldCell alloc] init];
    countCell.editable = NO;
    countCell.alignment = NSTextAlignmentRight;
    countCell.textColor = NSColor.secondaryLabelColor;
    countCell.font = cellFont;
    countCol.dataCell = countCell;
    [table addTableColumn:countCol];

    scroll.documentView = table;
    self.tableView = table;

    NSButton *deleteButton = [NSButton buttonWithTitle:@"–" target:self action:@selector(deleteSelected:)];
    deleteButton.bezelStyle = NSBezelStyleRounded;
    deleteButton.toolTip = @"Delete this persona and all of its records (after confirmation).";
    self.deleteButton = deleteButton;
    NSButton *mergeButton = [NSButton buttonWithTitle:@"Merge…" target:self action:@selector(mergeSelected:)];
    mergeButton.bezelStyle = NSBezelStyleRounded;
    mergeButton.toolTip = @"Re-stamp all of this persona's records onto another persona, then remove it.";
    self.mergeButton = mergeButton;
    NSStackView *rowButtons = [NSStackView stackViewWithViews:@[deleteButton, mergeButton]];
    rowButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowButtons.spacing = 6;

    self.statusLabel = [self es_labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;

    NSArray<NSView *> *all = @[heading, blurb, scroll, rowButtons, self.statusLabel];
    for (NSView *v in all) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }

    CGFloat m = 20;
    [NSLayoutConstraint activateConstraints:@[
        [root.widthAnchor constraintEqualToConstant:460],

        [heading.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [heading.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [heading.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [blurb.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:6],
        [blurb.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [blurb.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [scroll.topAnchor constraintEqualToAnchor:blurb.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [scroll.heightAnchor constraintEqualToConstant:170],

        [rowButtons.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:6],
        [rowButtons.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [self.statusLabel.topAnchor constraintEqualToAnchor:rowButtons.bottomAnchor constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
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
    [self reloadRows];
    [self updateState];
}

#pragma mark - Data load

- (void)reloadRows {
    NSDictionary<NSString *, NSNumber *> *counts = [self affectedCountsByAuthor];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *a in [self distinctArchiveAuthors]) {
        [rows addObject:@{kColAuthor: a, kColCount: (counts[a] ?: @0)}];
    }
    self.rows = rows;
    [self.tableView reloadData];
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
    if ([tableColumn.identifier isEqualToString:kColCount]) return r[kColCount];
    return r[kColAuthor];
}

#pragma mark - NSTableViewDelegate

- (BOOL)tableView:(NSTableView *)tableView
shouldEditTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)row {
    return NO; // all mutations go through the explicit dialogs
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateState];
}

#pragma mark - Selection helpers

- (nullable NSDictionary *)selectedRow {
    NSInteger idx = self.tableView.selectedRow;
    if (idx < 0 || idx >= (NSInteger)self.rows.count) return nil;
    return self.rows[idx];
}

- (void)updateState {
    NSDictionary *sel = [self selectedRow];
    self.deleteButton.enabled = (sel != nil);
    // Merging needs a second persona to merge into.
    self.mergeButton.enabled = (sel != nil && self.rows.count > 1);
}

- (void)showStatus:(NSString *)message {
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = message ?: @"";
}

#pragma mark - Delete

- (void)deleteSelected:(id)sender {
    NSDictionary *row = [self selectedRow];
    if (!row) return;
    NSString *name = row[kColAuthor];
    NSInteger count = [row[kColCount] integerValue];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"Delete persona “%@”?", name];
    alert.informativeText = [NSString stringWithFormat:
        @"This permanently deletes %ld record%@ authored by “%@” — memories "
        @"(including revisions), comments, and attachments. This cannot be undone.",
        (long)count, count == 1 ? @"" : @"s", name];
    NSButton *del = [alert addButtonWithTitle:@"Delete Persona"];
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];
    if (@available(macOS 11.0, *)) del.hasDestructiveAction = YES;
    del.keyEquivalent = @"";       // not the default
    cancel.keyEquivalent = @"\r";  // Return = Cancel (safe)

    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) [self deletePersona:name];
    };
    if (parent) [alert beginSheetModalForWindow:parent completionHandler:handle];
    else handle([alert runModal]);
}

- (void)deletePersona:(NSString *)name {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSInteger total = 0;

    // Capture this persona's tags BEFORE the delete: afterwards we cannot tell
    // which empty tags this operation orphaned and which were already empty.
    NSSet<NSManagedObjectID *> *tagsBefore = [ESTagJanitor tagIDsForAuthor:name context:ctx];
    // Delete everything stamped with this author. Deleting a memory also cascades
    // its own children (links/vectors/etc.) per the model's deletion rules; the
    // explicit comment/attachment passes also catch this persona's annotations on
    // OTHER personas' memories.
    for (NSString *entity in @[@"CDMemory", @"CDMarginalia", @"CDReference"]) {
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:entity];
        r.predicate = [NSPredicate predicateWithFormat:@"author == %@", name];
        NSArray<NSManagedObject *> *objs = [ctx executeFetchRequest:r error:nil] ?: @[];
        for (NSManagedObject *o in objs) { [ctx deleteObject:o]; total++; }
    }

    // Tags left with nothing on them are orphans of this delete — same transaction.
    NSArray<NSString *> *orphaned = [ESTagJanitor deleteOrphanedAmong:tagsBefore context:ctx];

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        [self es_presentWarningTitle:@"Delete failed"
                        message:saveErr.localizedDescription ?: @"Could not delete the records."];
        return;
    }

    [self reloadRows];
    [self updateState];
    NSString *tagNote = orphaned.count == 0 ? @""
        : [NSString stringWithFormat:@" %lu orphaned tag%@ removed.",
           (unsigned long)orphaned.count, orphaned.count == 1 ? @"" : @"s"];
    [self showStatus:[NSString stringWithFormat:@"Deleted %ld record%@ from “%@”.%@",
                      (long)total, total == 1 ? @"" : @"s", name, tagNote]];
}

#pragma mark - Merge

- (void)mergeSelected:(id)sender {
    NSDictionary *row = [self selectedRow];
    if (!row) return;
    NSString *source = row[kColAuthor];
    NSInteger count = [row[kColCount] integerValue];

    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    for (NSDictionary *r in self.rows) {
        NSString *a = r[kColAuthor];
        if (![a isEqualToString:source]) [targets addObject:a];
    }
    if (targets.count == 0) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Merge persona “%@”", source];
    alert.informativeText = [NSString stringWithFormat:
        @"All %ld record%@ authored by “%@” — memories (including revisions), "
        @"comments, and attachments — are re-stamped onto the persona you choose, "
        @"and “%@” disappears from the list.",
        (long)count, count == 1 ? @"" : @"s", source, source];
    [alert addButtonWithTitle:@"Merge"];
    [alert addButtonWithTitle:@"Cancel"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 280, 26) pullsDown:NO];
    [popup addItemsWithTitles:targets];
    alert.accessoryView = popup;

    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSString *target = popup.titleOfSelectedItem;
        if (target.length == 0 || [target isEqualToString:source]) return;
        [self mergePersonaFrom:source to:target];
    };
    if (parent) [alert beginSheetModalForWindow:parent completionHandler:handle];
    else handle([alert runModal]);
}

- (void)mergePersonaFrom:(NSString *)oldName to:(NSString *)newName {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSInteger total = 0;
    // Author lives on memories (incl. revision subentities), comments, and
    // attachments — move the identity everywhere it's stamped. The records,
    // their vectors, links and graph edges hang off the memory by relationship,
    // so re-stamping the author silently re-homes everything the persona owns.
    for (NSString *entity in @[@"CDMemory", @"CDMarginalia", @"CDReference"]) {
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:entity];
        r.predicate = [NSPredicate predicateWithFormat:@"author == %@", oldName];
        NSArray<NSManagedObject *> *objs = [ctx executeFetchRequest:r error:nil] ?: @[];
        for (NSManagedObject *o in objs) { [o setValue:newName forKey:kColAuthor]; total++; }
    }

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        [self es_presentWarningTitle:@"Merge failed"
                        message:saveErr.localizedDescription ?: @"Could not save the change."];
        return;
    }

    [self reloadRows];
    [self selectAuthor:newName];
    [self updateState];
    [self showStatus:[NSString stringWithFormat:@"Merged %ld record%@ from “%@” into “%@”.",
                      (long)total, total == 1 ? @"" : @"s", oldName, newName]];
}

- (void)selectAuthor:(NSString *)name {
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        if ([self.rows[i][kColAuthor] isEqualToString:name]) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:i];
            return;
        }
    }
}

#pragma mark - Helpers

#pragma mark - Presentation

+ (void)showPersonas {
    static NSWindowController *wc;
    if (!wc) {
        ESStdioPersonaController *vc = [[ESStdioPersonaController alloc] init];
        NSWindow *win = [NSWindow windowWithContentViewController:vc];
        win.title = @"ES Archive Personas";
        win.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        win.releasedWhenClosed = NO;
        [win center];
        wc = [[NSWindowController alloc] initWithWindow:win];
    }
    // Accessory (Minimal) apps open panels behind the frontmost app unless activated.
    [NSApp activateIgnoringOtherApps:YES];
    [wc showWindow:nil];   // -viewWillAppear reloads on each show
}

@end
