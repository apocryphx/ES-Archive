//
//  ESUntagPipelineFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESUntagPipelineFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "ESCoreDataStack.h"

@implementation ESUntagPipelineFilter {
    NSString *_tagName;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"untag"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;

        if (stage.flags.count > 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"untag: takes no flags. Usage: ... | untag NAME"}];
            }
            return nil;
        }

        if (stage.positional.count != 1 || ((NSString *)stage.positional.firstObject).length == 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"untag: requires exactly one tag name. Usage: ... | untag NAME"}];
            }
            return nil;
        }

        _tagName = stage.positional.firstObject;
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
                        @"untag: needs an input population (chain after lfind/grep/...)."}];
        }
        return @[];
    }

    CDTag *tag = [CDTag findByName:_tagName context:ctx];
    if (!tag) {
        if (errOut) {
            *errOut = [NSError errorWithDomain:@"ESPipelineError" code:5
                                      userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"untag: no such tag '%@'.", _tagName]}];
        }
        return @[];
    }

    for (NSManagedObjectID *oid in prior) {
        CDMemory *m = (CDMemory *)[ctx existingObjectWithID:oid error:NULL];
        if (m && ![m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
            [m removeTagsObject:tag];
        }
    }

    if (ctx.hasChanges) {
        NSError *saveErr = nil;
        if (![ctx save:&saveErr]) {
            if (errOut) *errOut = saveErr;
            return @[];
        }
    }

    return prior;
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
        @"    untag — detach a tag from every entry in the pipeline\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    ... | untag NAME\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Detaches the named tag from every entry in the input\n"
        @"    population. Entries that weren't carrying the tag are\n"
        @"    unaffected. All detachments commit atomically.\n"
        @"\n"
        @"    The tag itself is not deleted — it just loses its associations\n"
        @"    with this population. Use archive_tags mode=delete to drop the tag.\n"
        @"\n"
        @"    Pass-through: returns the input population unchanged.\n"
        @"\n"
        @"    Errors:\n"
        @"      - No input (used as the first stage of a pipeline).\n"
        @"      - Unknown tag name (typo guard — no silent no-op).\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Clear a curated subset entirely:\n"
        @"        lfind --tag \"Isoldes Stories\" | untag \"Isoldes Stories\"\n"
        @"\n"
        @"    Move entries from one subset to another:\n"
        @"        lfind --tag \"old-name\" | untag \"old-name\" | tag \"new-name\"\n"
        @"\n"
        @"SEE ALSO\n"
        @"    tag, lfind; the archive_tags tool for the catalog\n";
}

@end
