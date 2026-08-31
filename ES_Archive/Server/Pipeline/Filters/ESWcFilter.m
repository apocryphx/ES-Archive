//
//  ESWcFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESWcFilter.h"
#import "ESPipelineDiagnostic.h"

@implementation ESWcFilter {
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"wc"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) _stage = stage;
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    return prior ?: @[];
}

- (NSDictionary *)terminalResponseWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                      context:(NSManagedObjectContext *)ctx
                                        error:(NSError **)errOut {
    return @{ @"count": @((prior ?: @[]).count) };
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindCounter);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    wc — count results without surfacing them\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    PIPELINE | wc\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Cheap peek at population size. Useful for probing before\n"
        @"    committing to a more expensive pipeline.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    lfind --tag \"Isolde\" | wc\n"
        @"    lfind --tag \"Isolde\" | w2vgrep \"resurrection\" | wc\n"
        @"\n"
        @"SEE ALSO\n"
        @"    head\n";
}

@end
