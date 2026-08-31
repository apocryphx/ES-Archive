//
//  ESMemoryAuthorListTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_author_list
//  Builds a distinct author list directly from CDMemory records.
//  No external dependencies.
//

#import "ESMemoryAuthorListTool.h"

@implementation ESMemoryAuthorListTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_author_list",
        @"description": @"List the author identity in scope for this connection. Use this name as the value for the author disambiguation parameter.",
        @"annotations": @{
            @"readOnlyHint": @YES,
            @"destructiveHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{}
        }
    };
}


+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    // Under strict per-persona scoping the global distinct-author roster would
    // disclose the existence and names of other personas — itself private — and
    // is no longer actionable (those authors aren't readable from this port).
    // Return only the persona in scope. The global list lives behind the
    // unscoped maintenance surface, not here.
    NSArray *authors = scope.author.length > 0 ? @[scope.author] : @[];
    return @{
        @"authors": authors,
        @"count": @(authors.count)
    };
}

@end
