//
//  MCPLoggingDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPLoggingDispatcher.h"
#import "ESLog.h"

@implementation MCPLoggingDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"logging/setLevel"];
}

- (NSDictionary *)handleMethod:(NSString *)method
                        params:(NSDictionary *)params
                         scope:(ESRequestScope *)scope
                         error:(NSError **)error {
    if ([method isEqualToString:@"logging/setLevel"]) {
        NSString *level = params[@"level"] ?: @"info";
        ESLog(@"[MCPLogging] Set level to: %@", level);
        return @{@"status": @"ok", @"level": level};
    }

    if (error) {
        *error = [NSError errorWithDomain:@"MCPError" code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return nil;
}

@end
