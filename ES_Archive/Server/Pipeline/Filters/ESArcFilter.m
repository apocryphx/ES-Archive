//
//  ESArcFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESArcFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"

#pragma mark - Duration parsing

/// Parse "12h", "1d", "30m", "90s", "2w" — unsigned duration → seconds.
/// Returns 0 (and sets parsed=NO) on bad input. Used only for --window;
/// the bridge has its own signed-offset parser for relative-date semantics.
static NSTimeInterval ESArcParseDuration(NSString *input, BOOL *parsed) {
    if (parsed) *parsed = NO;
    if (![input isKindOfClass:NSString.class] || input.length == 0) return 0;

    NSString *trimmed = [input stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length == 0) return 0;

    // Optional leading '+' is tolerated; '-' is not — windows are unsigned.
    if ([trimmed hasPrefix:@"+"]) trimmed = [trimmed substringFromIndex:1];
    if ([trimmed hasPrefix:@"-"]) return 0;

    NSUInteger numEnd = 0;
    while (numEnd < trimmed.length &&
           [NSCharacterSet.decimalDigitCharacterSet
               characterIsMember:[trimmed characterAtIndex:numEnd]]) {
        numEnd++;
    }
    if (numEnd == 0) return 0;

    NSInteger value = [[trimmed substringToIndex:numEnd] integerValue];
    NSString *unit = [[trimmed substringFromIndex:numEnd]
                      stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (unit.length == 0) unit = @"h";  // bare number → hours (most common case)

    NSTimeInterval scale = 0;
    if ([@[@"s", @"sec", @"secs", @"second", @"seconds"] containsObject:unit]) {
        scale = 1;
    } else if ([@[@"m", @"min", @"mins", @"minute", @"minutes"] containsObject:unit]) {
        scale = 60;
    } else if ([@[@"h", @"hr", @"hrs", @"hour", @"hours"] containsObject:unit]) {
        scale = 60 * 60;
    } else if ([@[@"d", @"day", @"days"] containsObject:unit]) {
        scale = 60 * 60 * 24;
    } else if ([@[@"w", @"wk", @"week", @"weeks"] containsObject:unit]) {
        scale = 60 * 60 * 24 * 7;
    } else {
        return 0;
    }

    if (parsed) *parsed = YES;
    return (NSTimeInterval)value * scale;
}

#pragma mark - Filter

@implementation ESArcFilter {
    NSString * _Nullable _anchorID;       // x-coredata:// URI form
    NSString * _Nullable _anchorTitle;    // exact-match fallback
    NSTimeInterval _windowSeconds;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"arc"; }

// arc results' meaning is temporal proximity — a session-cluster without
// timestamps is just a list of titles, no way to see the temporal shape
// of what arrived together. Opt in to dateCreated on every rendered row.
+ (BOOL)requiresDateContext { return YES; }

- (nullable instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (!self) return nil;
    _stage = stage;
    _windowSeconds = 12 * 60 * 60;  // 12h default — matches the same-day clustering shape

    static NSSet<NSString *> *acceptedFlags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        acceptedFlags = [NSSet setWithArray:@[ @"anchor-id", @"anchor-title", @"window" ]];
    });
    for (NSString *flag in stage.flags) {
        if (![acceptedFlags containsObject:flag]) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:
                              @"arc: unknown flag '--%@'. Accepted: --anchor-id, --anchor-title, --window.", flag]}];
            }
            return nil;
        }
    }

    id idVal = stage.flags[@"anchor-id"];
    if ([idVal isKindOfClass:NSString.class] && [(NSString *)idVal length] > 0) {
        _anchorID = (NSString *)idVal;
    }

    id titleVal = stage.flags[@"anchor-title"];
    if ([titleVal isKindOfClass:NSString.class] && [(NSString *)titleVal length] > 0) {
        _anchorTitle = (NSString *)titleVal;
    }

    id windowVal = stage.flags[@"window"];
    if (windowVal) {
        NSString *str = nil;
        if ([windowVal isKindOfClass:NSString.class]) {
            str = (NSString *)windowVal;
        } else if ([windowVal isKindOfClass:NSNumber.class]) {
            // Bare integer → hours (matches the bare-number convention above).
            str = [NSString stringWithFormat:@"%@h", windowVal];
        }
        BOOL ok = NO;
        NSTimeInterval parsed = ESArcParseDuration(str, &ok);
        if (!ok || parsed <= 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:4
                                          userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:
                              @"arc: invalid --window value '%@'. Try '12h', '1d', '30m', '2w'.",
                              str ?: @""]}];
            }
            return nil;
        }
        _windowSeconds = parsed;
    }

    return self;
}

#pragma mark - Anchor resolution

/// Resolve the anchor memory in priority order: --id > --title > prior's first.
/// Returns nil with errOut set when no anchor can be found.
- (nullable CDMemory *)resolveAnchorWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                       context:(NSManagedObjectContext *)ctx
                                         error:(NSError **)errOut {
    NSPersistentStoreCoordinator *psc = ctx.persistentStoreCoordinator;

    if (_anchorID.length > 0) {
        NSURL *url = [NSURL URLWithString:_anchorID];
        NSManagedObjectID *moid = url ? [psc managedObjectIDForURIRepresentation:url] : nil;
        if (!moid) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ESPipelineError" code:5
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:
                                      @"arc: --anchor-id '%@' is not a valid entry id URI.", _anchorID]}];
            return nil;
        }
        NSError *fetchErr = nil;
        CDMemory *m = (CDMemory *)[ctx existingObjectWithID:moid error:&fetchErr];
        if (!m || ![m isKindOfClass:CDMemory.class]) {
            if (errOut) *errOut = fetchErr ?: [NSError errorWithDomain:@"ESPipelineError" code:6
                                                              userInfo:@{NSLocalizedDescriptionKey:
                                                @"arc: --anchor-id refers to a missing entry."}];
            return nil;
        }
        return m;
    }

    if (_anchorTitle.length > 0) {
        // Exact title match. If multiple, take the most recently modified.
        NSFetchRequest *fr = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        fr.includesSubentities = NO;
        fr.predicate = [NSPredicate predicateWithFormat:@"title == %@", _anchorTitle];
        fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];
        fr.fetchLimit = 1;
        NSError *fetchErr = nil;
        NSArray<CDMemory *> *rows = [ctx executeFetchRequest:fr error:&fetchErr];
        if (rows.count == 0) {
            if (errOut) *errOut = [NSError errorWithDomain:@"ESPipelineError" code:7
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:
                                      @"arc: no entry titled '%@'.", _anchorTitle]}];
            return nil;
        }
        return rows.firstObject;
    }

    if (prior.count > 0) {
        NSError *fetchErr = nil;
        NSManagedObject *obj = [ctx existingObjectWithID:prior.firstObject error:&fetchErr];
        if ([obj isKindOfClass:CDMemory.class]) return (CDMemory *)obj;
        if (errOut) *errOut = fetchErr ?: [NSError errorWithDomain:@"ESPipelineError" code:8
                                                          userInfo:@{NSLocalizedDescriptionKey:
                                                @"arc: upstream's first result is not an entry."}];
        return nil;
    }

    if (errOut) {
        *errOut = [NSError errorWithDomain:@"ESPipelineError" code:9
                                  userInfo:@{NSLocalizedDescriptionKey:
                    @"arc: no anchor — pipe in a result, or pass --anchor-id / --anchor-title."}];
    }
    return nil;
}

#pragma mark - Apply

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    CDMemory *anchor = [self resolveAnchorWithPrior:prior context:ctx error:errOut];
    if (!anchor) return @[];

    NSDate *t = anchor.dateCreated;
    if (!t) {
        if (errOut) *errOut = [NSError errorWithDomain:@"ESPipelineError" code:10
                                              userInfo:@{NSLocalizedDescriptionKey:
                                @"arc: anchor entry has no dateCreated."}];
        return @[];
    }

    NSDate *start = [t dateByAddingTimeInterval:-_windowSeconds];
    NSDate *end   = [t dateByAddingTimeInterval: _windowSeconds];

    NSFetchRequest *fr = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fr.includesSubentities = NO;
    fr.resultType = NSManagedObjectIDResultType;
    fr.predicate = [NSPredicate predicateWithFormat:
                    @"dateCreated >= %@ AND dateCreated <= %@", start, end];
    // Chronological — the arc reads forward in time, the way the session
    // actually unfolded. Reverse from the rest of the pipeline (which is
    // recency-first) but right for this stage: the user wants to follow the
    // arc as it was written, not browse it newest-first.
    fr.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES]];

    NSError *fetchErr = nil;
    NSArray<NSManagedObjectID *> *ids = [ctx executeFetchRequest:fr error:&fetchErr];
    if (fetchErr) {
        if (errOut) *errOut = fetchErr;
        return @[];
    }
    return ids ?: @[];
}

#pragma mark - Diagnostic

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindFilter);
}

#pragma mark - Man

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    arc — return the session-cluster around an anchor entry\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    arc [--window DURATION] [--anchor-id URI] [--anchor-title NAME]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Returns every entry whose dateCreated falls inside a window\n"
        @"    centered on an anchor entry. The default window (12h) matches\n"
        @"    the typical shape of a single working session — entries laid\n"
        @"    down together within roughly half a day of each other.\n"
        @"\n"
        @"    Use this to read an entry in context: a strong claim filed in\n"
        @"    one entry is often metabolized, widened, or empirically followed\n"
        @"    up by adjacent entries from the same session. Reading the arc\n"
        @"    forward (chronological order, oldest first) shows how the work\n"
        @"    actually unfolded.\n"
        @"\n"
        @"    Anchor resolution priority:\n"
        @"      --anchor-id URI    Anchor by managed-object-ID URI (exact).\n"
        @"      --anchor-title NAME\n"
        @"                         Anchor by exact title; ties broken by\n"
        @"                         most-recently-modified.\n"
        @"      <upstream>       First result of the upstream pipeline.\n"
        @"\n"
        @"    --window DURATION  Half-width of the window. Default 12h.\n"
        @"                       Accepts s/m/h/d/w units (e.g. '12h', '1d',\n"
        @"                       '30m', '2w'). A bare number is hours.\n"
        @"\n"
        @"    Output sort order is chronological ascending — the oldest\n"
        @"    entry in the window first, the anchor and its successors after.\n"
        @"    This is the reverse of the rest of the pipeline (which is\n"
        @"    recency-first) and is deliberate: the arc reads forward.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Read the session arc around a found entry:\n"
        @"        grep \"PAM critique\" --title | head 1 | arc\n"
        @"\n"
        @"    Wider window when the work bridged sleep:\n"
        @"        grep \"five-day arc\" --title | head 1 | arc --window 24h\n"
        @"\n"
        @"    Anchor directly by title:\n"
        @"        arc --anchor-title \"BGE-M3 Migration Complete\" --window 12h\n"
        @"\n"
        @"    Compose with downstream filters:\n"
        @"        lfind --tag \"research excursion\" | head 1 | arc | w2vgrep \"cosine\"\n"
        @"\n"
        @"SEE ALSO\n"
        @"    lfind, grep, head, w2vgrep\n";
}

@end
