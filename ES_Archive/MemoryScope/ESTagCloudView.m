//
//  ESTagCloudView.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTagCloudView.h"
#import "ESCoreDataStack.h"
#import "CDTag.h"
#import "CDMemory.h"

#pragma mark - Constants

static const CGFloat kMinFontSize   = 11.0;
static const CGFloat kMaxFontSize   = 52.0;
static const CGFloat kSpiralStep    = 3.0;
static const CGFloat kSpiralGrowth  = 0.4;
static const CGFloat kItemPadding   = 6.0;
static const NSUInteger kMaxSpiralIterations = 2000;
static const NSTimeInterval kReloadCoalesceDelay = 0.3;

static const NSUInteger kTagKindPaletteCount = 10;

static NSColor *kTagKindPalette[10];

static void ESInitTagKindPalette(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kTagKindPalette[0] = [NSColor colorWithSRGBRed:0.90 green:0.30 blue:0.25 alpha:1.0]; // red
        kTagKindPalette[1] = [NSColor colorWithSRGBRed:0.20 green:0.60 blue:0.86 alpha:1.0]; // blue
        kTagKindPalette[2] = [NSColor colorWithSRGBRed:0.30 green:0.75 blue:0.45 alpha:1.0]; // green
        kTagKindPalette[3] = [NSColor colorWithSRGBRed:0.95 green:0.60 blue:0.20 alpha:1.0]; // orange
        kTagKindPalette[4] = [NSColor colorWithSRGBRed:0.60 green:0.40 blue:0.80 alpha:1.0]; // purple
        kTagKindPalette[5] = [NSColor colorWithSRGBRed:0.85 green:0.45 blue:0.65 alpha:1.0]; // pink
        kTagKindPalette[6] = [NSColor colorWithSRGBRed:0.25 green:0.75 blue:0.75 alpha:1.0]; // teal
        kTagKindPalette[7] = [NSColor colorWithSRGBRed:0.75 green:0.65 blue:0.25 alpha:1.0]; // gold
        kTagKindPalette[8] = [NSColor colorWithSRGBRed:0.45 green:0.55 blue:0.70 alpha:1.0]; // slate
        kTagKindPalette[9] = [NSColor colorWithSRGBRed:0.55 green:0.80 blue:0.35 alpha:1.0]; // lime
    });
}

// OKLCH (L, C, h°) → sRGB NSColor. Out-of-gamut channels are clamped to [0,1].
static NSColor *ESColorFromOKLCH(CGFloat L, CGFloat C, CGFloat hDeg) {
    CGFloat hRad = hDeg * (CGFloat)M_PI / 180.0;
    CGFloat a = C * cos(hRad);
    CGFloat b = C * sin(hRad);

    CGFloat l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    CGFloat m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    CGFloat s_ = L - 0.0894841775 * a - 1.2914855480 * b;

    CGFloat l = l_ * l_ * l_;
    CGFloat m = m_ * m_ * m_;
    CGFloat s = s_ * s_ * s_;

    CGFloat lr =  4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    CGFloat lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    CGFloat lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    CGFloat (^toSRGB)(CGFloat) = ^CGFloat(CGFloat c) {
        c = MAX(0.0, MIN(1.0, c));
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    };
    return [NSColor colorWithSRGBRed:toSRGB(lr) green:toSRGB(lg) blue:toSRGB(lb) alpha:1.0];
}

// Semantic kind → color. An equilateral OKLCH triad anchored on the project green:
// project/person/principle sit at hues 150/30/270 (work / people / ideas);
// subset is a lighter sibling of principle; session/research are greyed transients.
static NSColor *ESSemanticColorForKind(NSString *kind) {
    static NSDictionary<NSString *, NSColor *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"project":   ESColorFromOKLCH(0.66, 0.135, 150),  // green
            @"person":    ESColorFromOKLCH(0.66, 0.135,  30),  // warm red
            @"principle": ESColorFromOKLCH(0.66, 0.135, 270),  // violet
            @"subset":    ESColorFromOKLCH(0.76, 0.085, 270),  // lighter violet
            @"session":   ESColorFromOKLCH(0.70, 0.045, 150),  // greyed green
            @"research":  ESColorFromOKLCH(0.70, 0.050,  30),  // greyed red
        };
    });
    return map[kind.lowercaseString];
}

static CGFloat ESTagFontSize(NSUInteger count, NSUInteger maxCount) {
    if (maxCount <= 1) return kMinFontSize;
    CGFloat t = log((CGFloat)count) / log((CGFloat)maxCount);
    return kMinFontSize + t * (kMaxFontSize - kMinFontSize);
}

#pragma mark - ESTagCloudItem

@interface ESTagCloudItem : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *kind;
@property (nonatomic)         NSUInteger count;
@property (nonatomic)         NSRect    placedRect;
@property (nonatomic, strong) NSFont   *font;
@property (nonatomic, strong) NSColor  *color;
@end

@implementation ESTagCloudItem

// A fresh item for one layout pass: the pass writes placedRect off-main, so
// passes never share items with each other or with drawing.
- (ESTagCloudItem *)layoutCopy {
    ESTagCloudItem *c = [[ESTagCloudItem alloc] init];
    c.name  = self.name;
    c.kind  = self.kind;
    c.count = self.count;
    c.font  = self.font;
    c.color = self.color;
    return c;
}

@end

#pragma mark - ESTagCloudView

@interface ESTagCloudView ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSColor *> *kindColorMap;
@property (nonatomic, strong) NSArray<ESTagCloudItem *> *items;        // counted, sorted, styled; unplaced
@property (nonatomic, strong) NSArray<ESTagCloudItem *> *layoutItems;  // placed, drawn
@property (nonatomic) BOOL needsReload;  // data changed while off-window
@property (nonatomic, strong) NSPopover *tagPopover;
@property (nonatomic) NSUInteger layoutGeneration;
@end

@implementation ESTagCloudView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self commonInit];
    return self;
}

- (void)commonInit {
    ESInitTagKindPalette();
    _kindColorMap = [NSMutableDictionary dictionary];
    _items = @[];
    _layoutItems = @[];
    _layoutGeneration = 0;
    _needsReload = YES;

    // Any change that reaches the view context — the host's own writes, merges,
    // CloudKit imports — posts here. A CDTag FRC missed memory-side changes
    // (e.g. an author edit) and knows nothing of personas; this sees both.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contextObjectsDidChange:)
                                                 name:NSManagedObjectContextObjectsDidChangeNotification
                                               object:[ESCoreDataStack shared].viewContext];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (BOOL)isFlipped {
    return YES;
}

#pragma mark - Tracking Areas

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
                      | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

#pragma mark - Change Tracking

- (void)setPersona:(nullable NSString *)persona {
    if (persona == _persona || [persona isEqualToString:_persona]) return;
    _persona = [persona copy];
    [self reloadTags];
}

// Tag membership lives on CDTag.memories, so every tag/untag, store, erase and
// merge touches a CDTag. A CDMemory author edit moves counts between personas
// without touching any tag. Local memory updates that leave author alone
// (reads bumping accessCount, body edits) are ignored; merged (refreshed)
// memories carry no changedValues, so they reload conservatively.
- (BOOL)changeAffectsCloud:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    if (info[NSInvalidatedAllObjectsKey]) return YES;
    for (NSString *key in @[NSInsertedObjectsKey, NSDeletedObjectsKey,
                            NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSInvalidatedObjectsKey]) {
        for (NSManagedObject *obj in info[key]) {
            if ([obj isKindOfClass:CDTag.class]) return YES;
            if (![obj isKindOfClass:CDMemory.class]) continue;
            if (![key isEqualToString:NSUpdatedObjectsKey]) return YES;
            if (obj.changedValues[@"author"]) return YES;
        }
    }
    return NO;
}

- (void)contextObjectsDidChange:(NSNotification *)note {
    if (![self changeAffectsCloud:note]) return;
    // Coalesce: a pipeline tagging fifty entries is one reload, not fifty.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadTags) object:nil];
    [self performSelector:@selector(reloadTags) withObject:nil afterDelay:kReloadCoalesceDelay];
}

#pragma mark - Color

- (NSColor *)colorForKind:(NSString *)kind {
    if (!kind || kind.length == 0) kind = @"thing";

    NSColor *cached = self.kindColorMap[kind];
    if (cached) return cached;

    NSColor *color = ESSemanticColorForKind(kind);
    if (!color) {
        // Unknown kind: fall back to a stable hash-assigned palette entry.
        NSUInteger hash = 0;
        for (NSUInteger i = 0; i < kind.length; i++) {
            hash = hash * 31 + [kind characterAtIndex:i];
        }
        color = kTagKindPalette[hash % kTagKindPaletteCount];
    }
    self.kindColorMap[kind] = color;
    return color;
}

#pragma mark - Layout

- (void)reloadTags {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadTags) object:nil];
    // Off-window (other tab, closed window): defer to -viewDidMoveToWindow.
    if (!self.window) {
        self.needsReload = YES;
        return;
    }
    self.needsReload = NO;

    NSManagedObjectContext *ctx = [ESCoreDataStack shared].viewContext;
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDTag"];
    fetch.relationshipKeyPathsForPrefetching = @[@"memories"];
    NSArray<CDTag *> *allTags = [ctx executeFetchRequest:fetch error:nil] ?: @[];
    NSString *persona = self.persona;

    // Count per tag — only the selected persona's memories, or all of them in
    // All (witness) mode. Filter count > 0, find max.
    NSMutableArray<ESTagCloudItem *> *items = [NSMutableArray array];
    NSUInteger maxCount = 1;

    for (CDTag *tag in allTags) {
        NSUInteger count = 0;
        if (persona) {
            for (CDMemory *m in tag.memories) {
                if ([m.author isEqualToString:persona]) count++;
            }
        } else {
            count = tag.memories.count;
        }
        if (count == 0) continue;

        ESTagCloudItem *item = [[ESTagCloudItem alloc] init];
        item.name  = tag.name ?: @"";
        item.kind  = tag.kind ?: @"thing";
        item.count = count;
        item.color = [self colorForKind:item.kind];
        [items addObject:item];

        if (count > maxCount) maxCount = count;
    }

    // Sort descending by count, then by name so equal counts place stably
    [items sortUsingComparator:^NSComparisonResult(ESTagCloudItem *a, ESTagCloudItem *b) {
        if (a.count > b.count) return NSOrderedAscending;
        if (a.count < b.count) return NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    // Compute fonts
    NSUInteger medianIdx = items.count / 2;
    for (NSUInteger i = 0; i < items.count; i++) {
        ESTagCloudItem *item = items[i];
        CGFloat fontSize = ESTagFontSize(item.count, maxCount);
        NSFontWeight weight = (i < medianIdx) ? NSFontWeightBold : NSFontWeightRegular;
        item.font = [NSFont systemFontOfSize:fontSize weight:weight];
    }

    self.items = items;
    [self rebuildLayout];
}

- (void)rebuildLayout {
    NSMutableArray<ESTagCloudItem *> *items = [NSMutableArray arrayWithCapacity:self.items.count];
    for (ESTagCloudItem *item in self.items) [items addObject:[item layoutCopy]];

    // Capture view bounds and generation for background layout
    NSSize viewSize = self.bounds.size;
    NSUInteger gen = ++self.layoutGeneration;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGPoint center = CGPointMake(viewSize.width * 0.5, viewSize.height * 0.5);
        NSMutableArray<NSValue *> *placedRects = [NSMutableArray array];

        for (ESTagCloudItem *item in items) {
            // Measure string
            NSDictionary *attrs = @{NSFontAttributeName: item.font};
            NSSize textSize = [item.name sizeWithAttributes:attrs];
            NSSize paddedSize = NSMakeSize(textSize.width + kItemPadding, textSize.height);

            BOOL placed = NO;
            CGFloat angle = 0;

            for (NSUInteger step = 0; step < kMaxSpiralIterations; step++) {
                CGFloat radius = kSpiralStep + kSpiralGrowth * angle;
                CGFloat cx = center.x + radius * cos(angle) - paddedSize.width * 0.5;
                CGFloat cy = center.y + radius * sin(angle) - paddedSize.height * 0.5;

                NSRect candidate = NSMakeRect(cx, cy, paddedSize.width, paddedSize.height);

                // Check collisions
                BOOL collision = NO;
                for (NSValue *rv in placedRects) {
                    if (NSIntersectsRect(candidate, rv.rectValue)) {
                        collision = YES;
                        break;
                    }
                }

                if (!collision) {
                    // Offset origin to account for padding (center text in padded rect)
                    item.placedRect = NSMakeRect(cx + kItemPadding * 0.5, cy, textSize.width, textSize.height);
                    [placedRects addObject:[NSValue valueWithRect:candidate]];
                    placed = YES;
                    break;
                }

                angle += 0.3;
            }

            if (!placed) {
                // Skip — overflow
                item.placedRect = NSZeroRect;
            }
        }

        // Remove items that couldn't be placed
        NSMutableArray<ESTagCloudItem *> *placedItems = [NSMutableArray array];
        for (ESTagCloudItem *item in items) {
            if (!NSIsEmptyRect(item.placedRect)) {
                [placedItems addObject:item];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // Only apply if this is still the current generation
            if (gen != self.layoutGeneration) return;
            self.layoutItems = placedItems;
            [self setNeedsDisplay:YES];
        });
    });
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor set];
    NSRectFill(self.bounds);

    for (ESTagCloudItem *item in self.layoutItems) {
        NSDictionary *attrs = @{
            NSFontAttributeName:            item.font,
            NSForegroundColorAttributeName: item.color,
        };
        [item.name drawAtPoint:item.placedRect.origin withAttributes:attrs];
    }

    // Empty state
    if (self.layoutItems.count == 0) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightLight],
            NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
            NSParagraphStyleAttributeName: style,
        };
        NSString *msg = @"No tags yet";
        NSSize sz = [msg sizeWithAttributes:attrs];
        CGRect bounds = self.bounds;
        [msg drawAtPoint:NSMakePoint((bounds.size.width - sz.width) * 0.5,
                                     (bounds.size.height - sz.height) * 0.5)
          withAttributes:attrs];
    }
}

#pragma mark - Interaction

- (nullable ESTagCloudItem *)hitTestItems:(NSPoint)point {
    for (ESTagCloudItem *item in self.layoutItems) {
        if (NSPointInRect(point, item.placedRect)) {
            return item;
        }
    }
    return nil;
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    ESTagCloudItem *hit = [self hitTestItems:loc];

    if (hit) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

- (void)mouseExited:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    ESTagCloudItem *hit = [self hitTestItems:loc];
    if (!hit) {
        [self dismissTagPopover];
        return;
    }

    [self dismissTagPopover];
    [self showPopoverForItem:hit];
}

- (void)showPopoverForItem:(ESTagCloudItem *)item {
    NSViewController *vc = [[NSViewController alloc] init];

    NSTextField *nameLabel = [NSTextField labelWithString:item.name];
    nameLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *kindLabel = [NSTextField labelWithString:item.kind];
    kindLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    kindLabel.textColor = NSColor.secondaryLabelColor;
    kindLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *countStr = [NSString stringWithFormat:@"%lu memories", (unsigned long)item.count];
    NSTextField *countLabel = [NSTextField labelWithString:countStr];
    countLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    countLabel.textColor = NSColor.tertiaryLabelColor;
    countLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSGlassEffectView *container = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    [container addSubview:nameLabel];
    [container addSubview:kindLabel];
    [container addSubview:countLabel];

    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [nameLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [nameLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],

        [kindLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [kindLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [kindLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],

        [countLabel.topAnchor constraintEqualToAnchor:kindLabel.bottomAnchor constant:2],
        [countLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [countLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
        [countLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];

    vc.view = container;

    self.tagPopover = [[NSPopover alloc] init];
    self.tagPopover.contentViewController = vc;
    self.tagPopover.behavior = NSPopoverBehaviorTransient;
    self.tagPopover.animates = YES;

    [self.tagPopover showRelativeToRect:item.placedRect
                                 ofView:self
                          preferredEdge:NSRectEdgeMinY];
}

- (void)dismissTagPopover {
    [self.tagPopover close];
    self.tagPopover = nil;
}

#pragma mark - Resize

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self rebuildLayout];
}

#pragma mark - View Lifecycle

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && self.needsReload) {
        [self reloadTags];
    }
}

@end
