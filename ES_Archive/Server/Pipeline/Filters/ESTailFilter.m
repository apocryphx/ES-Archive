//
//  ESTailFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTailFilter.h"
#import "ESPipelineDiagnostic.h"

@implementation ESTailFilter {
    NSInteger _n;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"tail"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _n = 10;
        if (stage.positional.count > 0) {
            NSInteger v = [stage.positional[0] integerValue];
            if (v > 0) _n = v;
        } else {
            id flagVal = stage.flags[@"limit"] ?: stage.flags[@"n"];
            if ([flagVal isKindOfClass:NSString.class]) {
                NSInteger v = [(NSString *)flagVal integerValue];
                if (v > 0) _n = v;
            } else if ([flagVal isKindOfClass:NSNumber.class]) {
                NSInteger v = [(NSNumber *)flagVal integerValue];
                if (v > 0) _n = v;
            }
        }
        if (_n < 0) _n = 0;
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    if (!prior) return @[];
    if ((NSUInteger)_n >= prior.count) return prior;
    return [prior subarrayWithRange:NSMakeRange(prior.count - _n, _n)];
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindSlice);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    tail — last N results from a population (diagnostic)\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    tail N\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Slice the last N entries. Useful diagnostically — the bottom of\n"
        @"    a semantic ranking shows what your filter is barely matching.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    w2vgrep \"file system\" | tail 5\n"
        @"\n"
        @"SEE ALSO\n"
        @"    head, sort\n";
}

@end
