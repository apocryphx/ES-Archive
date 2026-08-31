//
//  MCPFraming.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "MCPFraming.h"

NSString * _Nullable ESMBEncodeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString * _Nullable ESMBJSONRPCResult(id _Nullable rpcId, NSDictionary *result) {
    return ESMBEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"result": result ?: @{}
    });
}

NSString * _Nullable ESMBJSONRPCError(id _Nullable rpcId, NSInteger code, NSString *message) {
    return ESMBEncodeJSON(@{
        @"jsonrpc": @"2.0",
        @"id": rpcId ?: [NSNull null],
        @"error": @{ @"code": @(code), @"message": message ?: @"Error" }
    });
}
