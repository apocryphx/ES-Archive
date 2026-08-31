//
//  ESDiscoverFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESDiscoverFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDMarginalia.h"

static const NSTimeInterval kHotHalfLifeDays = 7.0;
static const double kHotLambda = 0.693147 / kHotHalfLifeDays;

@implementation ESDiscoverFilter {
    NSString *_mode;
    NSInteger _limit;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"discover"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;

        // Accept --mode or positional.
        id modeVal = stage.flags[@"mode"];
        if ([modeVal isKindOfClass:NSString.class] && [(NSString *)modeVal length] > 0) {
            _mode = (NSString *)modeVal;
        } else if (stage.positional.count > 0) {
            _mode = stage.positional[0];
        }

        if (_mode.length == 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:4
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"discover requires --mode (forgotten, hot, hubs, lost, popular, revised, discussed, fiction)"}];
            }
            return nil;
        }

        static NSSet *known;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            known = [NSSet setWithArray:@[@"popular", @"forgotten", @"lost",
                                           @"hubs", @"revised", @"discussed", @"hot",
                                           @"fiction"]];
        });
        if (![known containsObject:_mode]) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:5
                                          userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"discover: unknown mode '%@'.", _mode]}];
            }
            return nil;
        }

        _limit = 200;
        id limitVal = stage.flags[@"limit"];
        if ([limitVal isKindOfClass:NSString.class]) {
            NSInteger v = [(NSString *)limitVal integerValue];
            if (v > 0) _limit = v;
        } else if ([limitVal isKindOfClass:NSNumber.class]) {
            NSInteger v = [(NSNumber *)limitVal integerValue];
            if (v > 0) _limit = v;
        }
        if (_limit < 1) _limit = 1;
    }
    return self;
}

// Identity modes exclude invented narratives (type == "fiction") so a story
// cycle can't dominate a structural lens — the same invariant the MCP
// archive_discover tool enforces via identityScopeForAuthor:. The dedicated
// 'fiction' mode is the one place fiction surfaces.
static NSPredicate *NonFictionPredicate(void) {
    return [NSPredicate predicateWithFormat:@"(type == nil OR type !=[c] %@)", @"fiction"];
}

- (NSPredicate *)combinePredicate:(NSPredicate * _Nullable)base
                        withPrior:(NSArray<NSManagedObjectID *> * _Nullable)prior {
    NSPredicate *priorPred = prior
        ? [NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]]
        : nil;
    if (base && priorPred) return [NSCompoundPredicate andPredicateWithSubpredicates:@[base, priorPred]];
    return base ?: priorPred;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {

    // popular/forgotten/lost: pure NSFetchRequest with sort and limit.
    // hubs/revised/discussed/hot: in-memory sort by relationship counts.
    if ([_mode isEqualToString:@"popular"] ||
        [_mode isEqualToString:@"forgotten"] ||
        [_mode isEqualToString:@"lost"]) {

        NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
        fetch.includesSubentities = NO;
        fetch.fetchLimit = _limit;
        fetch.resultType = NSManagedObjectIDResultType;

        NSPredicate *base = nil;
        NSSortDescriptor *sort = nil;
        if ([_mode isEqualToString:@"popular"]) {
            base = NonFictionPredicate();
            sort = [NSSortDescriptor sortDescriptorWithKey:@"accessCount" ascending:NO];
        } else if ([_mode isEqualToString:@"forgotten"]) {
            base = [NSCompoundPredicate andPredicateWithSubpredicates:@[
                [NSPredicate predicateWithFormat:@"dateAccessed != nil"], NonFictionPredicate()]];
            sort = [NSSortDescriptor sortDescriptorWithKey:@"dateAccessed" ascending:YES];
        } else { // lost
            base = [NSCompoundPredicate andPredicateWithSubpredicates:@[
                [NSPredicate predicateWithFormat:@"dateAccessed == nil"], NonFictionPredicate()]];
            sort = [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES];
        }
        fetch.predicate = [self combinePredicate:base withPrior:prior];
        fetch.sortDescriptors = @[sort];

        NSError *err = nil;
        NSArray<NSManagedObjectID *> *ids = [ctx executeFetchRequest:fetch error:&err];
        if (err) {
            if (errOut) *errOut = err;
            return @[];
        }
        return ids ?: @[];
    }

    // In-memory sort modes.
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;

    NSPredicate *base = nil;
    if ([_mode isEqualToString:@"revised"])     base = [NSCompoundPredicate andPredicateWithSubpredicates:@[
                                                    [NSPredicate predicateWithFormat:@"revisions.@count > 0"], NonFictionPredicate()]];
    else if ([_mode isEqualToString:@"discussed"] ||
             [_mode isEqualToString:@"hot"])    base = [NSCompoundPredicate andPredicateWithSubpredicates:@[
                                                    [NSPredicate predicateWithFormat:@"marginalia.@count > 0"], NonFictionPredicate()]];
    else if ([_mode isEqualToString:@"fiction"]) base = [NSPredicate predicateWithFormat:@"type ==[c] %@", @"fiction"];
    else                                        base = NonFictionPredicate(); // hubs
    fetch.predicate = [self combinePredicate:base withPrior:prior];

    if ([_mode isEqualToString:@"hubs"] || [_mode isEqualToString:@"fiction"]) {
        // fiction sorts most-connected first, like hubs, so a cycle's
        // root/index entries lead — mirrors ESMemoryDiscoverTool.
        fetch.relationshipKeyPathsForPrefetching = @[@"sourceLinks", @"targetLinks"];
    } else if ([_mode isEqualToString:@"revised"]) {
        fetch.relationshipKeyPathsForPrefetching = @[@"revisions"];
    } else if ([_mode isEqualToString:@"discussed"] || [_mode isEqualToString:@"hot"]) {
        fetch.relationshipKeyPathsForPrefetching = @[@"marginalia"];
    }

    NSError *fetchErr = nil;
    NSArray<CDMemory *> *all = [ctx executeFetchRequest:fetch error:&fetchErr];
    if (fetchErr) {
        if (errOut) *errOut = fetchErr;
        return @[];
    }
    if (all.count == 0) return @[];

    NSArray<CDMemory *> *sorted;
    if ([_mode isEqualToString:@"hubs"] || [_mode isEqualToString:@"fiction"]) {
        sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
            NSUInteger ca = a.sourceLinks.count + a.targetLinks.count;
            NSUInteger cb = b.sourceLinks.count + b.targetLinks.count;
            return cb > ca ? NSOrderedDescending : (cb < ca ? NSOrderedAscending : NSOrderedSame);
        }];
    } else if ([_mode isEqualToString:@"revised"]) {
        sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
            return b.revisions.count > a.revisions.count ? NSOrderedDescending
                : (b.revisions.count < a.revisions.count ? NSOrderedAscending : NSOrderedSame);
        }];
    } else if ([_mode isEqualToString:@"discussed"]) {
        sorted = [all sortedArrayUsingComparator:^NSComparisonResult(CDMemory *a, CDMemory *b) {
            return b.marginalia.count > a.marginalia.count ? NSOrderedDescending
                : (b.marginalia.count < a.marginalia.count ? NSOrderedAscending : NSOrderedSame);
        }];
    } else {  // hot
        NSDate *now = [NSDate now];
        NSMutableArray<NSDictionary *> *scored = [NSMutableArray arrayWithCapacity:all.count];
        for (CDMemory *m in all) {
            double heat = 0.0;
            for (CDMarginalia *note in m.marginalia) {
                NSTimeInterval ageDays = [now timeIntervalSinceDate:note.dateCreated] / 86400.0;
                if (ageDays < 0) ageDays = 0;
                heat += exp(-kHotLambda * ageDays);
            }
            [scored addObject:@{@"m": m, @"h": @(heat)}];
        }
        [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ha = [a[@"h"] doubleValue];
            double hb = [b[@"h"] doubleValue];
            return hb > ha ? NSOrderedDescending : (hb < ha ? NSOrderedAscending : NSOrderedSame);
        }];
        NSMutableArray<CDMemory *> *byHeat = [NSMutableArray arrayWithCapacity:scored.count];
        for (NSDictionary *e in scored) [byHeat addObject:e[@"m"]];
        sorted = byHeat;
    }

    NSUInteger count = MIN((NSUInteger)_limit, sorted.count);
    NSMutableArray<NSManagedObjectID *> *out = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [out addObject:sorted[i].objectID];
    return out;
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindFilter);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    discover — structural lenses on the Archive\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    discover --mode forgotten|hot|hubs|lost|popular|revised|discussed|fiction [--limit N]\n"
        @"    discover MODE [--limit N]    # positional form\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Apply a structural mode to the Archive. Modes:\n"
        @"\n"
        @"    hot         where the conversation is now (recency-weighted marginalia)\n"
        @"    forgotten   accessed long ago, rarely — buried signal\n"
        @"    lost        never accessed — orphans waiting\n"
        @"    hubs        most connected — load-bearing nodes\n"
        @"    popular     most accessed — watch for orthodoxy\n"
        @"    revised     most edited — living documents\n"
        @"    discussed   most commented all-time\n"
        @"    fiction     invented narratives (type=fiction), most-connected first\n"
        @"\n"
        @"    Every mode except fiction excludes type=fiction, so an invented\n"
        @"    story cycle can't dominate a structural lens. fiction is the one\n"
        @"    place those entries surface.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Reorient at session start:\n"
        @"        discover --mode hot | head 5\n"
        @"\n"
        @"    Buried-signal recovery:\n"
        @"        discover --mode forgotten | w2vgrep \"vector embedding\" | head 10\n"
        @"\n"
        @"SEE ALSO\n"
        @"    lfind, w2vgrep\n";
}

@end
