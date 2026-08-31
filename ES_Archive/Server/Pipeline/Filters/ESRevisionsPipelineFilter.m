//
//  ESRevisionsPipelineFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESRevisionsPipelineFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"

@implementation ESRevisionsPipelineFilter {
    NSUInteger _min;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"revisions"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _min = 1;  // default: any memory with at least one revision

        static NSSet<NSString *> *acceptedFlags;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            acceptedFlags = [NSSet setWithArray:@[@"min"]];
        });
        for (NSString *flag in stage.flags) {
            if (![acceptedFlags containsObject:flag]) {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:
                                  @"revisions: unknown flag '--%@'. Accepted: --min.",
                                  flag]}];
                }
                return nil;
            }
        }

        if (stage.positional.count > 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"revisions: takes no positional args. Usage: ... | revisions [--min N]"}];
            }
            return nil;
        }

        id minVal = stage.flags[@"min"];
        if ([minVal isKindOfClass:NSString.class]) {
            NSInteger n = [(NSString *)minVal integerValue];
            if (n < 0) {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                @"revisions: --min must be a non-negative integer."}];
                }
                return nil;
            }
            _min = (NSUInteger)n;
        } else if ([minVal isKindOfClass:NSNumber.class]) {
            NSInteger n = [(NSNumber *)minVal integerValue];
            if (n < 0) {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                @"revisions: --min must be a non-negative integer."}];
                }
                return nil;
            }
            _min = (NSUInteger)n;
        }
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    if (!prior) {
        if (errOut) {
            *errOut = [NSError errorWithDomain:@"ESPipelineError" code:4
                                      userInfo:@{NSLocalizedDescriptionKey:
                        @"revisions: needs an input population (chain after lfind/grep/...). "
                         "For Archive-wide queries, start with `lfind`."}];
        }
        return @[];
    }

    NSMutableArray<NSManagedObjectID *> *result = [NSMutableArray arrayWithCapacity:prior.count];
    for (NSManagedObjectID *oid in prior) {
        CDMemory *m = (CDMemory *)[ctx existingObjectWithID:oid error:NULL];
        if (!m || [m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) continue;
        if (m.revisions.count >= _min) {
            [result addObject:oid];
        }
    }
    return result;
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
        @"    revisions — narrow a population to entries with at least N revisions\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    ... | revisions [--min N]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Filters the input population to entries whose revision count\n"
        @"    meets a threshold. Read-only.\n"
        @"\n"
        @"    --min N    Minimum revision count to include (default 1). Entries\n"
        @"               that have never been revised are dropped at the default.\n"
        @"               Use --min 0 to keep everything (a no-op pass-through);\n"
        @"               --min 3 to surface only entries that have been revised\n"
        @"               substantively (\"what keeps changing\").\n"
        @"\n"
        @"    Different from archive_revisions: that tool returns a single\n"
        @"    entry's full revision history (each revision's date, reason,\n"
        @"    title, body) for inspection. This filter returns a population\n"
        @"    of parent entries that meet the threshold, suitable for further\n"
        @"    pipeline composition.\n"
        @"\n"
        @"    Output preserves input order. Combine with `sort recent` to put\n"
        @"    the most-recently-revised first.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Recently changing thinking — what's been revised in the last month:\n"
        @"        lfind --days 30 | revisions | sort recent | head 10\n"
        @"\n"
        @"    Living documents — entries with substantive revision history:\n"
        @"        lfind | revisions --min 3 | sort recent | head 20\n"
        @"\n"
        @"    Within a project, what keeps moving:\n"
        @"        lfind --tag \"ES Archive\" | revisions --min 2\n"
        @"\n"
        @"    Combine with discover for a different lens (revision-edited entries,\n"
        @"    even old ones, ranked by recency of edit):\n"
        @"        discover --mode revised | head 30 | revisions --min 5 | head 10\n"
        @"\n"
        @"SEE ALSO\n"
        @"    archive_revisions, sort, lfind, discover\n";
}

@end
