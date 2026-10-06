//
//  ESMemoryPipelineTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryPipelineTool.h"
#import "ESPipelineExecutor.h"
#import "ESPipelineParser.h"

// Strip "uuid" fields from any results array in the response. The engine's
// structural surface (archive_pipeline) carries UUIDs for scripts and graph
// tools, but the LLM-facing archive_cli surface does not — UUIDs are machine
// identity, titles are the reading interface, and mixing them degrades the
// response for an audience that doesn't need machine identity.
static NSDictionary *StripUUIDsFromResponse(NSDictionary *response) {
    if (![response isKindOfClass:NSDictionary.class]) return response;
    NSArray *results = response[@"results"];
    if (![results isKindOfClass:NSArray.class]) return response;

    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:results.count];
    for (NSDictionary *row in results) {
        if (![row isKindOfClass:NSDictionary.class]) {
            [cleaned addObject:row];
            continue;
        }
        if (row[@"uuid"]) {
            NSMutableDictionary *copy = [row mutableCopy];
            [copy removeObjectForKey:@"uuid"];
            [cleaned addObject:[copy copy]];
        } else {
            [cleaned addObject:row];
        }
    }
    NSMutableDictionary *out = [response mutableCopy];
    out[@"results"] = cleaned;
    return [out copy];
}

@implementation ESMemoryPipelineTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_pipeline",
        @"description":
            @"Structural form of the archive_cli pipeline surface. Accepts "
             "either `expression` (the same string grammar archive_cli takes, "
             "e.g. \"lfind --tag X | w2vgrep 'concept' | head 5\") or `stages` "
             "(the pipeline pre-parsed as an array of stage dicts), exactly one "
             "of the two, and runs it through the ESPipelineFilter chain. "
             "Prefer archive_cli for interactive use; this tool is for batch "
             "tools, graph analysis, or non-LLM scripting that wants the "
             "structural form or needs entry UUIDs in the results.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"expression": @{
                    @"type": @"string",
                    @"description":
                        @"A pipeline expression in the archive_cli grammar. "
                         "Mutually exclusive with `stages`."
                },
                @"stages": @{
                    @"type": @"array",
                    @"description":
                        @"Ordered array of stage dicts. Each stage has shape "
                         "{name: string, positional: [string]?, flags: object?}. "
                         "Example: [{\"name\":\"lfind\",\"flags\":{\"tag\":\"X\"}}, "
                         "{\"name\":\"head\",\"positional\":[\"5\"]}]. "
                         "Mutually exclusive with `expression`.",
                    @"items": @{
                        @"type": @"object",
                        @"properties": @{
                            @"name":       @{ @"type": @"string" },
                            @"positional": @{ @"type": @"array", @"items": @{ @"type": @"string" } },
                            @"flags":      @{ @"type": @"object" }
                        },
                        @"required": @[ @"name" ]
                    }
                }
            }
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    id expression = arguments[@"expression"];
    id stages     = arguments[@"stages"];
    BOOL hasExpression = [expression isKindOfClass:NSString.class];
    BOOL hasStages     = [stages isKindOfClass:NSArray.class];

    if (hasExpression == hasStages) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                @"Pass exactly one of `expression` (a pipeline string) or "
                 "`stages` (an array of stage dicts)."}];
        }
        return nil;
    }

    if (hasExpression) {
        return [self executeExpression:expression
                       persistentStore:store
                                 scope:scope
                            stripUUIDs:NO];
    }
    return [self executeStages:stages persistentStore:store scope:scope];
}

+ (NSDictionary *)executeExpression:(NSString *)expression
                    persistentStore:(NSPersistentCloudKitContainer *)store
                              scope:(ESRequestScope *)scope
                         stripUUIDs:(BOOL)stripUUIDs {
    NSError *parseErr = nil;
    NSArray<NSDictionary *> *stages = ESPipelineParseExpression(expression, &parseErr);
    if (!stages) {
        // The parse-error shape is part of the archive_cli interface: skills
        // and man pages describe it, so it is returned as a result, not as a
        // JSON-RPC error.
        return @{
            @"error":      @"parse_error",
            @"message":    parseErr.localizedDescription ?: @"could not parse",
            @"expression": expression,
        };
    }
    if (stages.count == 0) {
        return @{
            @"error":   @"empty_pipeline",
            @"message": @"No commands. Try 'man' to see what's available.",
        };
    }

    NSDictionary *response = [self executeStages:stages persistentStore:store scope:scope];
    return stripUUIDs ? StripUUIDsFromResponse(response) : response;
}

+ (NSDictionary *)executeStages:(NSArray<NSDictionary *> *)stages
                persistentStore:(NSPersistentCloudKitContainer *)store
                          scope:(ESRequestScope *)scope {
    // Core Data work runs on the main queue. Same discipline as other
    // read-only tools.
    __block NSDictionary *result = nil;
    NSString *scopeAuthor = scope.author;
    dispatch_block_t block = ^{
        result = ESPipelineExecute(stages, store.viewContext, scopeAuthor);
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    return result ?: @{};
}

@end
