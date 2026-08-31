//
//  MCPFraming.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  JSON-RPC 2.0 framing helpers for the stdio transport. Carried over
//  verbatim from ES-Memory-Bridge so the wire encoding stays identical.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Encode an NSDictionary as a compact JSON string. Returns nil on failure.
NSString * _Nullable ESMBEncodeJSON(NSDictionary *obj);

/// Build a JSON-RPC 2.0 success response. `rpcId` of nil becomes JSON null.
NSString * _Nullable ESMBJSONRPCResult(id _Nullable rpcId, NSDictionary *result);

/// Build a JSON-RPC 2.0 error response. `rpcId` of nil becomes JSON null.
NSString * _Nullable ESMBJSONRPCError(id _Nullable rpcId, NSInteger code, NSString *message);

NS_ASSUME_NONNULL_END
