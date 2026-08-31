//
//  ESMemoryPipelineTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryPipelineTool.h"
#import "ESPipelineExecutor.h"

@implementation ESMemoryPipelineTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_pipeline",
        @"description":
            @"Server-side pipeline executor for the archive_cli surface. "
             "Accepts a parsed pipeline as an array of stages and runs them "
             "through the ESPipelineFilter chain. This tool is bridge-facing; "
             "AI calls archive_cli on the bridge, which marshals to this "
             "tool. Direct callers may use this for batch tools, graph "
             "analysis, or non-LLM scripting.",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"stages": @{
                    @"type": @"array",
                    @"description":
                        @"Ordered array of stage dicts. Each stage has shape "
                         "{name: string, positional: [string]?, flags: object?}. "
                         "Example: [{\"name\":\"lfind\",\"flags\":{\"tag\":\"X\"}}, "
                         "{\"name\":\"head\",\"positional\":[\"5\"]}]",
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
            },
            @"required": @[ @"stages" ]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSArray *stages = arguments[@"stages"];
    if (![stages isKindOfClass:NSArray.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                @"`stages` is required and must be an array of stage dicts."}];
        }
        return nil;
    }

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
