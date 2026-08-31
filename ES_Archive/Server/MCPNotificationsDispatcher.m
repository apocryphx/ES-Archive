//
//  MCPNotificationsDispatcher.m
//  MCPServer
//
//  Created by Kolja Wawrowsky on 9/13/25.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPNotificationsDispatcher.h"

@implementation MCPNotificationsDispatcher

+ (NSArray<NSString *> *)methodNames {
    return @[@"notifications/initialized", @"notifications/progress", @"notifications/message"];
}

- (NSDictionary *)handleMethod:(NSString *)method
                        params:(NSDictionary *)params
                         scope:(ESRequestScope *)scope
                         error:(NSError **)error {
    // Notifications are typically fire-and-forget; acknowledge receipt
    if ([method isEqualToString:@"notifications/initialized"]) {
        return @{@"status": @"acknowledged"};
    }
    else if ([method isEqualToString:@"notifications/progress"]) {
        return @{@"status": @"acknowledged"};
    }
    else if ([method isEqualToString:@"notifications/message"]) {
        return @{@"status": @"acknowledged"};
    }

    if (error) {
        *error = [NSError errorWithDomain:@"MCPError" code:-32601
                                 userInfo:@{NSLocalizedDescriptionKey: @"Method not found"}];
    }
    return nil;
}

@end
