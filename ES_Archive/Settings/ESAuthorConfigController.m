//
//  ESAuthorConfigController.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESAuthorConfigController.h"
#import "ESServerConfig.h"
#import "ESCoreDataStack.h"
#import "ESTagJanitor.h"
#import "NSViewController+ESUIHelpers.h"
#import "MCPServer.h"

static NSString * const kColAuthor = @"author";
static NSString * const kColCount  = @"count";   // records a rename/delete would touch
static NSString * const kRowExisting = @"existing"; // BOOL: author has records in the archive

@interface ESAuthorConfigController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSButton *removeButton;
@property (nonatomic, strong) NSButton *renameButton;
@property (nonatomic, strong) NSButton *mergeButton;
@property (nonatomic, strong) NSTextField *statusLabel;

/// One row per persona: {author: NSString, count: NSNumber, existing: NSNumber(BOOL)}.
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@end

@implementation ESAuthorConfigController

#pragma mark - Shared author list

+ (NSArray<NSString *> *)allKnownAuthors {
    NSMutableArray<NSString *> *authors = [[self distinctArchiveAuthors] mutableCopy];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithArray:authors];
    for (NSString *a in [ESServerConfig declaredAuthors]) {
        if (![seen containsObject:a]) { [authors addObject:a]; [seen addObject:a]; }
    }
    // Bound-but-undeclared authors (pre-split port maps) still count as personas.
    for (NSString *a in [[ESServerConfig portAuthorMap] allValues]) {
        if (![seen containsObject:a]) { [authors addObject:a]; [seen addObject:a]; }
    }
    [authors sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return authors;
}

+ (NSArray<NSString *> *)distinctArchiveAuthors {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].persistentContainer.viewContext;
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

#pragma mark - View

- (void)loadView {
    self.title = @"Personas";

    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 380)];

    NSTextField *heading = [self es_labelWithString:@"Personas"];
    heading.font = [NSFont boldSystemFontOfSize:13];

    NSTextField *blurb = [self es_labelWithString:
        @"Every author in the archive is a persona. Use + to create one, – to "
        @"delete one together with all of its records, Rename… to re-stamp its "
        @"records under a new name, and Merge… to fold its records into another "
        @"persona. Which port serves which persona is set on the Ports pane."];
    blurb.font = [NSFont systemFontOfSize:11];
    blurb.textColor = NSColor.secondaryLabelColor;
    blurb.lineBreakMode = NSLineBreakByWordWrapping;
    blurb.maximumNumberOfLines = 0;
    blurb.preferredMaxLayoutWidth = 480; // wrap rather than stretch the window

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

    NSButton *addButton = [NSButton buttonWithTitle:@"+" target:self action:@selector(createPersona:)];
    addButton.bezelStyle = NSBezelStyleRounded;
    addButton.toolTip = @"Create a new persona";
    NSButton *removeButton = [NSButton buttonWithTitle:@"–" target:self action:@selector(deleteSelected:)];
    removeButton.bezelStyle = NSBezelStyleRounded;
    removeButton.toolTip = @"Delete this persona and all of its records (after confirmation).";
    self.removeButton = removeButton;
    NSButton *renameButton = [NSButton buttonWithTitle:@"Rename…" target:self action:@selector(renameSelected:)];
    renameButton.bezelStyle = NSBezelStyleRounded;
    renameButton.toolTip = @"Rename this persona across all its records.";
    self.renameButton = renameButton;
    NSButton *mergeButton = [NSButton buttonWithTitle:@"Merge…" target:self action:@selector(mergeSelected:)];
    mergeButton.bezelStyle = NSBezelStyleRounded;
    mergeButton.toolTip = @"Re-stamp all of this persona's records onto another persona, then remove it.";
    self.mergeButton = mergeButton;
    NSStackView *rowButtons = [NSStackView stackViewWithViews:@[addButton, removeButton, renameButton, mergeButton]];
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
        [root.widthAnchor constraintEqualToConstant:520],

        [heading.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [heading.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [heading.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [blurb.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:6],
        [blurb.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [blurb.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [scroll.topAnchor constraintEqualToAnchor:blurb.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [scroll.heightAnchor constraintEqualToConstant:190],

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
    for (NSString *a in [ESAuthorConfigController allKnownAuthors]) {
        NSNumber *count = counts[a] ?: @0;
        [rows addObject:@{kColAuthor: a,
                          kColCount: count,
                          kRowExisting: @(count.integerValue > 0)}];
    }
    self.rows = rows;
    [self.tableView reloadData];
}

/// Records a rename/merge/delete would touch, per author: memories (incl.
/// revision subentities), comments, and attachments — exactly the entities
/// -performRestampFrom:to: walks, so the column is an honest blast-radius
/// preview.
- (NSDictionary<NSString *, NSNumber *> *)affectedCountsByAuthor {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].persistentContainer.viewContext;
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

- (void)selectAuthor:(NSString *)name {
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        if ([self.rows[i][kColAuthor] isEqualToString:name]) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:i];
            return;
        }
    }
}

- (void)updateState {
    NSDictionary *sel = [self selectedRow];
    self.removeButton.enabled = (sel != nil);
    self.renameButton.enabled = (sel != nil);
    // Merging needs a second persona to merge into.
    self.mergeButton.enabled = (sel != nil && self.rows.count > 1);
}

- (void)showStatus:(NSString *)message {
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.stringValue = message ?: @"";
}

#pragma mark - Create

- (void)createPersona:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"New persona";
    alert.informativeText = @"The name is stamped as the author on every record "
                             "this persona writes. Bind it to a port on the Ports "
                             "pane to serve it.";
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.placeholderString = @"Persona name";
    alert.accessoryView = field;

    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceCharacterSet];
        if (name.length == 0) return;
        for (NSDictionary *r in self.rows) {
            if ([r[kColAuthor] localizedCaseInsensitiveCompare:name] == NSOrderedSame) {
                [self es_presentWarningTitle:@"Persona already exists"
                                message:[NSString stringWithFormat:@"“%@” is already in the list.", r[kColAuthor]]];
                return;
            }
        }
        NSMutableArray *declared = [[ESServerConfig declaredAuthors] mutableCopy];
        [declared addObject:name];
        [ESServerConfig setDeclaredAuthors:declared];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self reloadRows];
        [self selectAuthor:name];
        [self updateState];
        [self showStatus:[NSString stringWithFormat:@"Created persona “%@”.", name]];
    };
    if (parent) {
        [alert beginSheetModalForWindow:parent completionHandler:handle];
        [parent makeFirstResponder:field];
    } else {
        handle([alert runModal]);
    }
}

#pragma mark - Delete

- (void)deleteSelected:(id)sender {
    NSDictionary *row = [self selectedRow];
    if (!row) return;
    NSString *name = row[kColAuthor];
    NSInteger count = [row[kColCount] integerValue];

    // A declared persona with no records: nothing destructive, just undeclare it.
    if (count == 0) {
        [self removeDeclaredAuthor:name];
        BOOL mapChanged = [self unbindPortsForAuthor:name];
        [self reloadRows];
        [self updateState];
        [self finishOperationWithSummary:[NSString stringWithFormat:@"Removed persona “%@”.", name]
                              mapChanged:mapChanged
                            alertMessage:@"Persona removed"];
        return;
    }

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
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].persistentContainer.viewContext;
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

    // Tags left with nothing on them are orphans of this delete — drop them in
    // the same transaction.
    NSArray<NSString *> *orphaned = [ESTagJanitor deleteOrphanedAmong:tagsBefore context:ctx];

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        [self es_presentWarningTitle:@"Delete failed"
                        message:saveErr.localizedDescription ?: @"Could not delete the records."];
        return;
    }

    [self removeDeclaredAuthor:name];
    BOOL mapChanged = [self unbindPortsForAuthor:name];

    [self reloadRows];
    [self updateState];

    NSString *tagNote = orphaned.count == 0 ? @""
        : [NSString stringWithFormat:@" %lu tag%@ left with no memories %@ also removed.",
           (unsigned long)orphaned.count, orphaned.count == 1 ? @"" : @"s",
           orphaned.count == 1 ? @"was" : @"were"];
    NSString *summary = [NSString stringWithFormat:@"Deleted %ld record%@ from “%@”.%@%@",
        (long)total, total == 1 ? @"" : @"s", name, tagNote,
        mapChanged ? @" Its port is now unbound — relaunch to apply." : @""];
    [self finishOperationWithSummary:summary mapChanged:mapChanged alertMessage:@"Persona deleted"];
}

#pragma mark - Rename

- (void)renameSelected:(id)sender {
    NSDictionary *row = [self selectedRow];
    if (!row) return;
    NSString *oldName = row[kColAuthor];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Rename persona “%@”", oldName];
    alert.informativeText = @"Every record authored by this persona is re-stamped "
                             "with the new name. If the new name already exists, the "
                             "two personas merge.";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = oldName;
    [field selectText:nil];
    alert.accessoryView = field;

    NSWindow *parent = self.view.window;
    void (^handle)(NSModalResponse) = ^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSString *newName = [field.stringValue stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet];
        if (newName.length == 0 || [newName isEqualToString:oldName]) return;
        [self performRestampFrom:oldName to:newName verb:@"Renamed"];
    };
    if (parent) {
        // Make the text field first responder once the sheet is on screen.
        [alert beginSheetModalForWindow:parent completionHandler:handle];
        [parent makeFirstResponder:field];
    } else {
        handle([alert runModal]);
    }
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
        [self performRestampFrom:source to:target verb:@"Merged"];
    };
    if (parent) [alert beginSheetModalForWindow:parent completionHandler:handle];
    else handle([alert runModal]);
}

#pragma mark - Re-stamp (shared by rename & merge)

- (void)performRestampFrom:(NSString *)oldName to:(NSString *)newName verb:(NSString *)verb {
    NSManagedObjectContext *ctx = [ESCoreDataStack shared].persistentContainer.viewContext;
    NSInteger total = 0;
    // Author lives on memories (incl. revision subentities), comments, and
    // attachments — move the identity everywhere it's stamped.
    for (NSString *entity in @[@"CDMemory", @"CDMarginalia", @"CDReference"]) {
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:entity];
        r.predicate = [NSPredicate predicateWithFormat:@"author == %@", oldName];
        NSArray<NSManagedObject *> *objs = [ctx executeFetchRequest:r error:nil] ?: @[];
        for (NSManagedObject *o in objs) { [o setValue:newName forKey:kColAuthor]; total++; }
    }

    NSError *saveErr = nil;
    if (![ctx save:&saveErr]) {
        [self es_presentWarningTitle:[NSString stringWithFormat:@"%@ failed", verb]
                        message:saveErr.localizedDescription ?: @"Could not save the change."];
        return;
    }

    // The old name is gone as an identity; a rename target with no records yet
    // must be declared or it would vanish from the list.
    [self removeDeclaredAuthor:oldName];
    if (total == 0) {
        NSMutableArray *declared = [[ESServerConfig declaredAuthors] mutableCopy];
        if (![declared containsObject:newName]) {
            [declared addObject:newName];
            [ESServerConfig setDeclaredAuthors:declared];
        }
    }

    // Follow the identity in the port map: any port bound to the old name now
    // binds the new one (so a live persona keeps its port across rename/merge).
    NSDictionary<NSNumber *, NSString *> *map = [ESServerConfig portAuthorMap];
    NSMutableDictionary<NSNumber *, NSString *> *newMap = [NSMutableDictionary dictionary];
    BOOL mapChanged = NO;
    for (NSNumber *p in map) {
        NSString *a = map[p];
        if ([a isEqualToString:oldName]) { a = newName; mapChanged = YES; }
        newMap[p] = a;
    }
    if (mapChanged) {
        [ESServerConfig setPortAuthorMap:newMap];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self reloadRows];
    [self selectAuthor:newName];
    [self updateState];

    NSString *summary = [NSString stringWithFormat:
        @"%@ %ld record%@ from “%@” to “%@”.%@",
        verb, (long)total, total == 1 ? @"" : @"s", oldName, newName,
        mapChanged ? @" A bound port now serves the new name — relaunch to apply." : @""];
    [self finishOperationWithSummary:summary
                          mapChanged:mapChanged
                        alertMessage:[NSString stringWithFormat:@"Persona %@", verb.lowercaseString]];
}

#pragma mark - Port map / declared list upkeep

- (void)removeDeclaredAuthor:(NSString *)name {
    NSMutableArray *declared = [[ESServerConfig declaredAuthors] mutableCopy];
    if ([declared containsObject:name]) {
        [declared removeObject:name];
        [ESServerConfig setDeclaredAuthors:declared];
    }
}

/// Drops any port binding (+ JWT flag) that pointed at the given persona.
/// Returns YES when a live binding was removed (a relaunch is then needed).
- (BOOL)unbindPortsForAuthor:(NSString *)name {
    NSDictionary<NSNumber *, NSString *> *map = [ESServerConfig portAuthorMap];
    NSMutableDictionary<NSNumber *, NSString *> *newMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *newJWT = [[ESServerConfig portJWTMap] mutableCopy];
    BOOL mapChanged = NO;
    for (NSNumber *p in map) {
        if ([map[p] isEqualToString:name]) { mapChanged = YES; [newJWT removeObjectForKey:p]; continue; }
        newMap[p] = map[p];
    }
    if (mapChanged) {
        [ESServerConfig setPortAuthorMap:newMap];
        [ESServerConfig setPortJWTMap:newJWT];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    return mapChanged;
}

/// A completed operation either just posts a status line, or — when it changed
/// a live port binding — offers the relaunch that makes the binding change real.
- (void)finishOperationWithSummary:(NSString *)summary
                        mapChanged:(BOOL)mapChanged
                      alertMessage:(NSString *)alertMessage {
    if (!mapChanged) {
        [self showStatus:summary];
        return;
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = alertMessage;
    a.informativeText = summary;
    [a addButtonWithTitle:@"Quit & Reopen"];
    [a addButtonWithTitle:@"Later"];
    NSWindow *parent = self.view.window;
    void (^h)(NSModalResponse) = ^(NSModalResponse resp){ if (resp == NSAlertFirstButtonReturn) [self es_relaunchApplication]; };
    if (parent) [a beginSheetModalForWindow:parent completionHandler:h];
    else h([a runModal]);
}

#pragma mark - Relaunch

#pragma mark - Helpers

@end
