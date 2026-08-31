//
//  ESSortFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESSortFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"

@implementation ESSortFilter {
    NSString *_byKey;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"sort"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;

        // Accept positional first (`sort oldest`), then --by.
        NSString *key = stage.positional.firstObject;
        if (key.length == 0) {
            id flagVal = stage.flags[@"by"];
            if ([flagVal isKindOfClass:NSString.class]) key = (NSString *)flagVal;
        }
        if (![key isKindOfClass:NSString.class] || key.length == 0) key = @"recent";

        // Canonicalize intuitive synonyms before validation. "title" is what
        // users reach for; "alphabetical" is the engineering name. Accept
        // both so the user's first guess works.
        if ([key isEqualToString:@"title"]) key = @"alphabetical";

        static NSSet *known;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            known = [NSSet setWithArray:@[@"recent", @"oldest", @"popular",
                                           @"accessed", @"alphabetical"]];
        });
        if (![known containsObject:key]) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:2
                                          userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:
                              @"sort: unknown key '%@'. Try one of: recent, oldest, popular, accessed, title (or alphabetical).",
                              key]}];
            }
            return nil;
        }
        _byKey = key;
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    if (!prior || prior.count == 0) return @[];

    // Use a server-side sort via NSFetchRequest, returning IDs only.
    // Avoids materializing every memory just to sort.
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    fetch.predicate = [NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]];
    fetch.resultType = NSManagedObjectIDResultType;

    if ([_byKey isEqualToString:@"popular"]) {
        fetch.sortDescriptors = @[
            [NSSortDescriptor sortDescriptorWithKey:@"accessCount" ascending:NO],
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ];
    } else if ([_byKey isEqualToString:@"alphabetical"]) {
        fetch.sortDescriptors = @[
            [NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES
                                            selector:@selector(caseInsensitiveCompare:)],
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ];
    } else if ([_byKey isEqualToString:@"oldest"]) {
        fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES]];
    } else if ([_byKey isEqualToString:@"accessed"]) {
        fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateAccessed" ascending:NO]];
    } else {
        fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];
    }

    NSError *err = nil;
    NSArray<NSManagedObjectID *> *sorted = [ctx executeFetchRequest:fetch error:&err];
    if (err) {
        if (errOut) *errOut = err;
        return @[];
    }
    return sorted ?: @[];
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindReorder);
}

#pragma mark - Phase 2: fusion contributions

- (NSArray<NSSortDescriptor *> *)sortDescriptorContribution {
    if ([_byKey isEqualToString:@"popular"]) {
        return @[
            [NSSortDescriptor sortDescriptorWithKey:@"accessCount" ascending:NO],
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ];
    }
    if ([_byKey isEqualToString:@"alphabetical"]) {
        return @[
            [NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES
                                            selector:@selector(caseInsensitiveCompare:)],
            [NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES],
        ];
    }
    if ([_byKey isEqualToString:@"oldest"]) {
        return @[[NSSortDescriptor sortDescriptorWithKey:@"dateCreated" ascending:YES]];
    }
    if ([_byKey isEqualToString:@"accessed"]) {
        return @[[NSSortDescriptor sortDescriptorWithKey:@"dateAccessed" ascending:NO]];
    }
    // recent (default)
    return @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];
}

#pragma mark -

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    sort — reorder a population\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    sort KEY                     # positional (preferred)\n"
        @"    sort --by KEY                # equivalent flag form\n"
        @"\n"
        @"    KEY: recent | oldest | popular | accessed | title\n"
        @"         (alphabetical is accepted as a synonym for title)\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Reorder the prior population by a metadata field. Default key\n"
        @"    is 'recent' (dateModified desc). Unknown keys error rather than\n"
        @"    silently defaulting.\n"
        @"\n"
        @"    recent       Most recently modified first.\n"
        @"    oldest       Earliest created first.\n"
        @"    popular      Highest accessCount first; tie-break by oldest.\n"
        @"    accessed     Most recently accessed first.\n"
        @"    title        Case-insensitive A→Z by title.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    lfind --tag \"Isolde\" | sort popular | head 10\n"
        @"    lfind --tag \"Kolja\"  | sort oldest  | head 5\n"
        @"    lfind --tag \"Isolde\" | sort title   | head 20\n"
        @"\n"
        @"SEE ALSO\n"
        @"    head, tail\n";
}

@end
