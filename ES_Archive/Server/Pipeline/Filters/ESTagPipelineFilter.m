//
//  ESTagPipelineFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTagPipelineFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "ESCoreDataStack.h"

@implementation ESTagPipelineFilter {
    NSString *_tagName;
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"tag"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;

        // No flags accepted; reject unknown ones with a clear message.
        if (stage.flags.count > 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"tag: takes no flags. Usage: ... | tag NAME"}];
            }
            return nil;
        }

        if (stage.positional.count != 1 || ((NSString *)stage.positional.firstObject).length == 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"tag: requires exactly one tag name. Usage: ... | tag NAME"}];
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
                        @"tag: needs an input population (chain after lfind/grep/...)."}];
        }
        return @[];
    }

    CDTag *tag = [CDTag findByName:_tagName context:ctx];
    if (!tag) {
        if (errOut) {
            *errOut = [NSError errorWithDomain:@"ESPipelineError" code:5
                                      userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:
                          @"tag: no such tag '%@'. Create it first with archive_tags mode=create.",
                          _tagName]}];
        }
        return @[];
    }

    for (NSManagedObjectID *oid in prior) {
        CDMemory *m = (CDMemory *)[ctx existingObjectWithID:oid error:NULL];
        if (m && ![m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
            [m addTagsObject:tag];
        }
    }

    if (ctx.hasChanges) {
        NSError *saveErr = nil;
        if (![ctx save:&saveErr]) {
            if (errOut) *errOut = saveErr;
            return @[];
        }
    }

    // Pass-through: same population, now carrying the tag. Lets callers
    // chain `... | tag X | head 20` to inspect what was tagged.
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
        @"    tag — attach an existing tag to every entry in the pipeline\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    ... | tag NAME\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Attaches the named tag to every entry in the input population.\n"
        @"    The tag must already exist (provision it with the archive_tags\n"
        @"    tool, mode=create). Tag names are unique — matched case- and\n"
        @"    diacritic-insensitively, across all kinds — so create returns\n"
        @"    already_exists and creates nothing when the name is taken. All\n"
        @"    attachments commit in a single Core Data transaction — atomic.\n"
        @"\n"
        @"    Pass-through: the population is returned unchanged so further\n"
        @"    stages can compose (`tag X | head 5` to confirm what landed).\n"
        @"\n"
        @"    Errors:\n"
        @"      - No input (used as the first stage of a pipeline).\n"
        @"      - Unknown tag name. Tags are deliberate; create explicitly.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Build a curated subset from search:\n"
        @"        archive_tags(mode=create, name=\"Isoldes Stories\", kind=subset)\n"
        @"        grep Isolde | grep Myth | tag \"Isoldes Stories\"\n"
        @"\n"
        @"    Apply a session tag to today's working set:\n"
        @"        archive_tags(mode=create, name=\"session-2026-05-04\", kind=session, expiresAt=\"+30 days\")\n"
        @"        lfind --days 1 | tag \"session-2026-05-04\"\n"
        @"\n"
        @"SEE ALSO\n"
        @"    untag, lfind, grep; the archive_tags tool for the catalog\n";
}

@end
