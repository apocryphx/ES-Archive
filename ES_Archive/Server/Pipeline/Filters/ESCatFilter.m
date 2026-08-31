//
//  ESCatFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESCatFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDMemoryLookup.h"

@implementation ESCatFilter {
    ESPipelineStage *_stage;
    NSString * _Nullable _titleArg;
}

+ (NSString *)commandName { return @"cat"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _titleArg = stage.positional.firstObject;
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    // Drives the diagnostic line. If we have a prior, pass it through;
    // otherwise resolve the positional title to one objectID.
    if (prior) return prior;
    if (_titleArg.length == 0) return @[];

    CDMemoryLookupResult *lookup = [CDMemoryLookup findMemoryWithTitle:_titleArg
                                                                 author:_stage.flags[@"author"]
                                                                  index:_stage.flags[@"index"]
                                                                context:ctx];
    if (lookup.status == CDMemoryLookupFound) {
        return @[lookup.memory.objectID];
    }
    return @[];
}

- (NSDictionary *)terminalResponseWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                      context:(NSManagedObjectContext *)ctx
                                        error:(NSError **)errOut {
    NSISO8601DateFormatter *df = [CDMemoryLookup sharedFormatter];

    NSArray<NSManagedObjectID *> *toRead = prior ?: @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:toRead.count];

    for (NSManagedObjectID *oid in toRead) {
        NSError *err = nil;
        NSManagedObject *obj = [ctx existingObjectWithID:oid error:&err];
        if (err || ![obj isKindOfClass:CDMemory.class]) continue;
        CDMemory *m = (CDMemory *)obj;
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"title"]        = m.title ?: @"Untitled";
        row[@"body"]         = m.body ?: @"";
        if (m.summary.length > 0)  row[@"summary"]      = m.summary;
        if (m.author.length > 0)   row[@"author"]       = m.author;
        if (m.type.length > 0)     row[@"type"]         = m.type;
        if (m.dateCreated)          row[@"dateCreated"]  = [df stringFromDate:m.dateCreated];
        if (m.dateModified)         row[@"dateModified"] = [df stringFromDate:m.dateModified];
        if (m.uuid)                 row[@"uuid"]         = m.uuid.UUIDString;
        [out addObject:row];
    }

    return @{ @"results": out, @"count": @(out.count) };
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindReader);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    cat — read full entry body\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    cat \"Title\"\n"
        @"    PIPELINE | cat\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Read full body, summary, and metadata. With a positional title,\n"
        @"    looks up that specific entry. With a prior pipeline, returns\n"
        @"    full entry dicts for the population.\n"
        @"\n"
        @"SCOPING\n"
        @"    To read only the top N results in full, pipe through head first:\n"
        @"\n"
        @"        grep \"topic\" | head 3 | cat\n"
        @"        w2vgrep \"concept phrase\" | head 2 | cat\n"
        @"\n"
        @"    cat without head reads all results in the current population. On\n"
        @"    large result sets, always scope with head first — otherwise the\n"
        @"    response floods context with every matching body before triage.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    cat \"The Crystalline Homecoming\"\n"
        @"    w2vgrep \"resurrection\" | head 1 | cat\n"
        @"    grep \"Isolde\" | head 3 | cat\n"
        @"\n"
        @"SEE ALSO\n"
        @"    lfind, w2vgrep, head\n";
}

@end
