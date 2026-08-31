//
//  MCPPromptsDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPPromptsDispatcher.h"

@implementation MCPPromptsDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"prompts/list", @"prompts/get"];
}

- (NSDictionary *)handleMethod:(NSString *)method
                        params:(NSDictionary *)params
                         scope:(ESRequestScope *)scope
                         error:(NSError **)error {
    if ([method isEqualToString:@"prompts/list"]) {
        return @{@"prompts": @[]};
    }
    else if ([method isEqualToString:@"prompts/get"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Prompt not found"}];
        }
        return nil;
    }

    if (error) {
        *error = [NSError errorWithDomain:@"MCPError" code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return nil;
}

@end
