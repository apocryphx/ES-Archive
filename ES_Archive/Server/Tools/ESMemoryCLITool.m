//
//  ESMemoryCLITool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryCLITool.h"
#import "ESMemoryPipelineTool.h"

@implementation ESMemoryCLITool

+ (NSDictionary *)requestJSON {
    static NSDictionary *schema = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        schema = @{
            @"name": @"archive_cli",
            @"description":
                @"Unix-pipeline-style surface for ES Archive. Compose retrieval and "
                 "curatorial operations with `|` exactly the way you would in a shell.\n\n"
                 "Start with `man` to see the full command vocabulary, then `man <command>` "
                 "for any specific command. The system documents itself.\n\n"
                 "Quick examples:\n"
                 "  archive_cli(\"man\")\n"
                 "  archive_cli(\"lfind --tag 'Isolde' | head 5\")\n"
                 "  archive_cli(\"lfind --tag-kind project | wc\")\n"
                 "  archive_cli(\"discover --mode forgotten | w2vgrep 'continuity' | head 10\")\n"
                 "  archive_cli(\"grep Isolde | grep Myth | tag 'Isoldes Stories'\")  // curatorial\n\n"
                 "Most stages read; `tag` and `untag` write (atomic per pipeline). If "
                 "results disappoint, vary the pipeline: reorder stages, replace one "
                 "command with another at the same position, or change a parameter and "
                 "re-run. Be persistent. Be creative. You will find it eventually.",
            @"annotations": @{ @"readOnlyHint": @NO, @"destructiveHint": @NO },
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"expression": @{
                        @"type": @"string",
                        @"description": @"A pipeline expression. Run archive_cli(\"man\") to list commands."
                    }
                },
                @"required": @[ @"expression" ]
            }
        };
    });
    return schema;
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *expression = arguments[@"expression"];
    if (![expression isKindOfClass:NSString.class] || expression.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32602
                                     userInfo:@{NSLocalizedDescriptionKey:
                @"`expression` is required. Try archive_cli(\"man\") to see commands."}];
        }
        return nil;
    }

    return [ESMemoryPipelineTool executeExpression:expression
                                   persistentStore:store
                                             scope:scope
                                        stripUUIDs:YES];
}

@end
