//
//  MCPResourcesDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPResourcesDispatcher.h"

@implementation MCPResourcesDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"resources/list", @"resources/read", @"resources/subscribe", @"resources/unsubscribe"];
}

- (NSDictionary *)handleMethod:(NSString *)method
                        params:(NSDictionary *)params
                         scope:(ESRequestScope *)scope
                         error:(NSError **)error {
    if ([method isEqualToString:@"resources/list"]) {
        return @{@"resources": @[]};
    }
    else if ([method isEqualToString:@"resources/read"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MCPError" code:-32001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Resource not found"}];
        }
        return nil;
    }
    else if ([method isEqualToString:@"resources/subscribe"] ||
             [method isEqualToString:@"resources/unsubscribe"]) {
        return @{@"status": @"ok"};
    }

    if (error) {
        *error = [NSError errorWithDomain:@"MCPError" code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return nil;
}

@end
