//
//  ESLfindFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESLfindFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "CDTag+CoreDataProperties.h"

@implementation ESLfindFilter {
    NSString * _Nullable _tag;
    NSArray<NSString *> * _Nullable _andTags;
    NSString * _Nullable _tagKind;
    NSString * _Nullable _author;
    NSNumber * _Nullable _days;
    BOOL _includeExpired;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"lfind"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;

        // Reject unknown flags up front. The previous "silently ignore"
        // behavior produced a particularly nasty bug shape: --author
        // (unrecognized) plus no other filter → empty clauses array →
        // unconditional fetch over the full archive, which looked like
        // success. Fail loudly instead so typos and unsupported flags
        // surface immediately.
        static NSSet<NSString *> *acceptedFlags;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            acceptedFlags = [NSSet setWithArray:@[
                @"tag", @"tags", @"tag-kind", @"author", @"days", @"include-expired"
            ]];
        });
        for (NSString *flag in stage.flags) {
            if (![acceptedFlags containsObject:flag]) {
                if (errOut) {
                    *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                              userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:
                                  @"lfind: unknown flag '--%@'. Accepted: --tag, --tags, --tag-kind, --author, --days, --include-expired.",
                                  flag]}];
                }
                return nil;
            }
        }

        id tagVal = stage.flags[@"tag"];
        if ([tagVal isKindOfClass:NSString.class] && [(NSString *)tagVal length] > 0) {
            _tag = (NSString *)tagVal;
        }

        // --tags "A,B,C" : AND of multiple tags. Comma-separated string
        // form (CLI-friendly) and array form (programmatic callers) both
        // accepted. Whitespace around each tag name is trimmed so callers
        // can write "Isolde, ES Archive" naturally.
        id tagsVal = stage.flags[@"tags"];
        NSMutableArray<NSString *> *cleaned = [NSMutableArray array];
        if ([tagsVal isKindOfClass:NSString.class]) {
            NSArray<NSString *> *parts = [(NSString *)tagsVal componentsSeparatedByString:@","];
            NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
            for (NSString *p in parts) {
                NSString *trimmed = [p stringByTrimmingCharactersInSet:ws];
                if (trimmed.length > 0) [cleaned addObject:trimmed];
            }
        } else if ([tagsVal isKindOfClass:NSArray.class]) {
            for (id v in (NSArray *)tagsVal) {
                if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 0) {
                    [cleaned addObject:v];
                }
            }
        }
        if (cleaned.count > 0) _andTags = [cleaned copy];

        // --tag-kind KIND : memories carrying at least one tag of this kind
        // (where the tag is non-expired unless --include-expired is set).
        id kindVal = stage.flags[@"tag-kind"];
        if ([kindVal isKindOfClass:NSString.class] && [(NSString *)kindVal length] > 0) {
            _tagKind = (NSString *)kindVal;
        }

        // --author NAME : exact-match filter on CDMemory.author. The author
        // field is a plain string set per-memory at creation/update time
        // ("Claude", "Kolja", "Isolde", etc.). Exact match matches the
        // semantics of --tag (also exact); use grep against the full corpus
        // for substring author search.
        id authorVal = stage.flags[@"author"];
        if ([authorVal isKindOfClass:NSString.class] && [(NSString *)authorVal length] > 0) {
            _author = (NSString *)authorVal;
        }

        id daysVal = stage.flags[@"days"];
        if ([daysVal isKindOfClass:NSString.class]) {
            NSInteger d = [(NSString *)daysVal integerValue];
            if (d > 0) _days = @(d);
        } else if ([daysVal isKindOfClass:NSNumber.class]) {
            NSInteger d = [(NSNumber *)daysVal integerValue];
            if (d > 0) _days = @(d);
        }

        // --include-expired : escape hatch. Boolean-only flag; the bridge
        // CLI's booleanOnlyFlags set normalizes this into @YES.
        id expiredVal = stage.flags[@"include-expired"];
        if ([expiredVal isKindOfClass:NSNumber.class]) {
            _includeExpired = [(NSNumber *)expiredVal boolValue];
        } else if ([expiredVal isKindOfClass:NSString.class]) {
            NSString *s = [(NSString *)expiredVal lowercaseString];
            _includeExpired = [s isEqualToString:@"true"] ||
                              [s isEqualToString:@"yes"]  ||
                              [s isEqualToString:@"1"]    ||
                              s.length == 0;  // bare flag with no value
        }
    }
    return self;
}

// Returns YES if `tag` is past its expiration (and expired-mode is off).
- (BOOL)isFiltered:(CDTag *)tag {
    if (_includeExpired) return NO;
    if (!tag.dateExpired) return NO;
    return [tag.dateExpired compare:[NSDate now]] == NSOrderedAscending;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.resultType = NSManagedObjectIDResultType;

    NSMutableArray<NSPredicate *> *clauses = [NSMutableArray array];

    if (_tag) {
        CDTag *tag = [CDTag findByName:_tag context:ctx];
        if (!tag || [self isFiltered:tag]) {
            // No such tag, or expired (and --include-expired not set).
            // Either way: empty result. Not an error.
            return @[];
        }
        [clauses addObject:[NSPredicate predicateWithFormat:@"ANY tags == %@", tag]];
    }

    // AND-of-tags: one ANY clause per resolved CDTag. The compound AND
    // ensures every named tag is present on the memory. Index-friendly
    // because each ANY clause can use the relationship's foreign key.
    // Any missing or expired tag short-circuits to empty result.
    if (_andTags) {
        for (NSString *name in _andTags) {
            CDTag *tag = [CDTag findByName:name context:ctx];
            if (!tag || [self isFiltered:tag]) return @[];
            [clauses addObject:[NSPredicate predicateWithFormat:@"ANY tags == %@", tag]];
        }
    }

    if (_tagKind) {
        // SUBQUERY form so we can express both kind-match and the per-tag
        // expiration check in one clause. ANY tags.kind == X can't carry the
        // expiration condition since it doesn't bind a per-tag variable.
        NSPredicate *p;
        if (_includeExpired) {
            p = [NSPredicate predicateWithFormat:
                 @"SUBQUERY(tags, $t, $t.kind ==[c] %@).@count > 0",
                 _tagKind];
        } else {
            p = [NSPredicate predicateWithFormat:
                 @"SUBQUERY(tags, $t, $t.kind ==[c] %@ AND ($t.dateExpired == nil OR $t.dateExpired > %@)).@count > 0",
                 _tagKind, [NSDate now]];
        }
        [clauses addObject:p];
    }

    if (_author) {
        [clauses addObject:[NSPredicate predicateWithFormat:@"author == %@", _author]];
    }

    if (_days != nil) {
        NSDate *cutoff = [[NSCalendar currentCalendar]
            dateByAddingUnit:NSCalendarUnitDay
                       value:-_days.integerValue
                      toDate:[NSDate now]
                     options:0];
        [clauses addObject:[NSPredicate predicateWithFormat:@"dateModified >= %@", cutoff]];
    }

    if (prior) {
        [clauses addObject:[NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]]];
    }

    if (clauses.count == 1) {
        fetch.predicate = clauses.firstObject;
    } else if (clauses.count > 1) {
        fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:clauses];
    }

    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];

    NSError *err = nil;
    NSArray<NSManagedObjectID *> *ids = [ctx executeFetchRequest:fetch error:&err];
    if (err) {
        if (errOut) *errOut = err;
        return @[];
    }
    return ids ?: @[];
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindLfind);
}

#pragma mark - Phase 2: fusion contributions

// lfind contributes the WHERE clause (tag predicate AND days predicate).
// Returns nil if no flags were specified, in which case lfind matches all.
- (NSPredicate *)predicateContributionWithContext:(NSManagedObjectContext *)ctx {
    NSMutableArray<NSPredicate *> *clauses = [NSMutableArray array];

    if (_tag) {
        CDTag *tag = [CDTag findByName:_tag context:ctx];
        if (!tag || [self isFiltered:tag]) {
            return [NSPredicate predicateWithValue:NO];
        }
        [clauses addObject:[NSPredicate predicateWithFormat:@"ANY tags == %@", tag]];
    }

    if (_andTags) {
        for (NSString *name in _andTags) {
            CDTag *tag = [CDTag findByName:name context:ctx];
            if (!tag || [self isFiltered:tag]) return [NSPredicate predicateWithValue:NO];
            [clauses addObject:[NSPredicate predicateWithFormat:@"ANY tags == %@", tag]];
        }
    }

    if (_tagKind) {
        NSPredicate *p;
        if (_includeExpired) {
            p = [NSPredicate predicateWithFormat:
                 @"SUBQUERY(tags, $t, $t.kind ==[c] %@).@count > 0",
                 _tagKind];
        } else {
            p = [NSPredicate predicateWithFormat:
                 @"SUBQUERY(tags, $t, $t.kind ==[c] %@ AND ($t.dateExpired == nil OR $t.dateExpired > %@)).@count > 0",
                 _tagKind, [NSDate now]];
        }
        [clauses addObject:p];
    }

    if (_author) {
        [clauses addObject:[NSPredicate predicateWithFormat:@"author == %@", _author]];
    }

    if (_days != nil) {
        NSDate *cutoff = [[NSCalendar currentCalendar]
            dateByAddingUnit:NSCalendarUnitDay
                       value:-_days.integerValue
                      toDate:[NSDate now]
                     options:0];
        [clauses addObject:[NSPredicate predicateWithFormat:@"dateModified >= %@", cutoff]];
    }

    if (clauses.count == 0) return nil;
    if (clauses.count == 1) return clauses.firstObject;
    return [NSCompoundPredicate andPredicateWithSubpredicates:clauses];
}

// lfind's default ordering. Overridden by an explicit sort filter later in
// the fusion run (sort's contribution comes last and the executor uses
// last-wins semantics).
- (NSArray<NSSortDescriptor *> *)sortDescriptorContribution {
    return @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];
}

#pragma mark -

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    lfind — filter entries by metadata\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    lfind [--tag NAME] [--tags \"A,B,C\"] [--tag-kind KIND]\n"
        @"          [--author NAME] [--days N] [--include-expired]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Filter the Archive by structured metadata. With no flags, returns\n"
        @"    every entry in the Archive (sorted by recency).\n"
        @"\n"
        @"    --tag NAME         Only entries carrying this exact tag.\n"
        @"    --tags A,B,C       Only entries carrying ALL named tags. Comma-\n"
        @"                       separated, whitespace-tolerant. Use this for\n"
        @"                       intersection queries — \"Isolde AND ES Archive\".\n"
        @"    --tag-kind KIND    Only entries carrying at least one tag of this\n"
        @"                       descriptive kind (person, place, project,\n"
        @"                       principle, subset, session, research).\n"
        @"    --author NAME      Only entries whose author == NAME (exact\n"
        @"                       match: \"Claude\", \"Kolja\", \"Isolde\", ...).\n"
        @"    --days N           Only entries modified in the last N days.\n"
        @"    --include-expired  Include tags whose dateExpired has passed.\n"
        @"                       Default: expired tags are filtered out, so\n"
        @"                       --tag and --tag-kind for an expired tag\n"
        @"                       return zero results.\n"
        @"\n"
        @"    Flags combine: --tag X --author Y requires both. A tag name that\n"
        @"    doesn't exist in the Archive yields zero results (the AND can\n"
        @"    never be satisfied). Unknown flags are rejected with an error.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    All entries tagged 'Isolde':\n"
        @"        lfind --tag \"Isolde\" | head 10\n"
        @"\n"
        @"    Entries carrying both tags (intersection):\n"
        @"        lfind --tags \"Isolde, ES Archive\" | head 10\n"
        @"\n"
        @"    Everything tagged with any project tag:\n"
        @"        lfind --tag-kind project | head 20\n"
        @"\n"
        @"    Entries Kolja authored in the last month:\n"
        @"        lfind --author \"Kolja\" --days 30 | head 10\n"
        @"\n"
        @"    Resurface a paused research thread:\n"
        @"        lfind --tag \"hot path investigation\" --include-expired\n"
        @"\n"
        @"    Refine by concept:\n"
        @"        lfind --tag \"ES Archive\" | w2vgrep \"branching\" | head 5\n"
        @"\n"
        @"    Last week's activity:\n"
        @"        lfind --days 7 | head 10\n"
        @"\n"
        @"SEE ALSO\n"
        @"    w2vgrep, head, tag, untag\n";
}

@end
