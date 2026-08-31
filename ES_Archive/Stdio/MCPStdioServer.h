//
//  MCPStdioServer.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  STDIO MCP transport. Three-queue architecture, carried over from
//  ES-Memory-Bridge (which matched ES Kairos):
//    - esm.stdio.read  (serial)     : stdin readabilityHandler → drainLines
//    - esm.stdio.work  (concurrent) : one block per inbound JSON-RPC line
//    - esm.stdio.write (serial)     : serializes writes to the JSON-RPC fd
//
//  Requests are served in-process by ESEngine — there is no HTTP hop and
//  no network listener anywhere in this target. The engine's dispatch
//  layer does its own main-thread funneling (it serves multiple HTTP
//  connections concurrently in the server target), so lines are handed to
//  it straight from the concurrent work queue with no extra serialization.
//
//  Shutdown is client-owned: stdin EOF or SIGTERM triggers a drain of the
//  three queues in order, then a Core Data save, then terminate.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCPStdioServer : NSObject

/// The private descriptor JSON-RPC responses are written to. main() dups
/// fd 1 into this before redirecting fd 1 → stderr, so a stray printf can
/// never corrupt a frame. Must be called before +shared.
+ (void)setRPCFileDescriptor:(int)fd;

+ (instancetype)shared;
- (void)start;

@end

NS_ASSUME_NONNULL_END
