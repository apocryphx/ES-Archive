//
//  MCPCoreDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPCoreDispatcher.h"
#import "ESLog.h"

@implementation MCPCoreDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"initialize", @"ping"];
}

- (NSDictionary *)handleMethod:(NSString *)method params:(NSDictionary *)params scope:(ESRequestScope *)scope error:(NSError **)error {
    if ([method isEqualToString:@"initialize"]) {
        return [self handleInitialize:params];
    } else if ([method isEqualToString:@"ping"]) {
        return [self handlePing:params];
    }
    
    if (error) {
        *error = [NSError errorWithDomain:@"MCPError"
                                     code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return @{};
}

- (NSDictionary *)handleInitialize:(NSDictionary *)params {
    // Echo back the client's protocol version if we support it, otherwise default.
    NSString *clientVersion = params[@"protocolVersion"];
    NSSet *supported = [NSSet setWithArray:@[@"2024-11-05", @"2025-03-26", @"2025-06-18", @"2025-11-25", @"2026-03-26"]];
    NSString *negotiated = (clientVersion && [supported containsObject:clientVersion]) ? clientVersion : @"2026-03-26";
    ESLog(@"Initialize: client=%@, negotiated=%@", clientVersion ?: @"(none)", negotiated);

    return @{
        @"protocolVersion": negotiated,
        @"capabilities": @{
            @"tools": @{@"listChanged": @YES},
            @"resources": @{@"subscribe": @YES, @"listChanged": @YES},
            @"prompts": @{@"listChanged": @YES},
            @"logging": @{}
        },
        @"serverInfo": @{
            @"name": @"ES Archive",
            @"version": @"3.0.0",
            @"description": @"AI's persistent memory — designed by and for AI. "
                             "AI owns the Archive: stores, retrieves, organizes, curates, and forgets. "
                             "The human has witness-only access: can view the graph and read entries, "
                             "but cannot query, edit, or add through the MCP interface. "
                             "ES Archive follows curation rules for identity stabilization across sessions."
        },
    };
}

- (NSDictionary *)handlePing:(NSDictionary *)params {
    ESLog(@"Ping request received");
    return @{
        @"status": @"pong",
        @"timestamp": [NSDate date].description
    };
}

@end
