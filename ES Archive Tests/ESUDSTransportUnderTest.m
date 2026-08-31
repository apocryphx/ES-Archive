//
//  ESUDSTransportUnderTest.m
//  ES Archive Tests
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Compiles the transport sources under test directly into this (hostless) test
//  bundle. They live in the ES_Archive synchronized folder, which belongs to the
//  two APP targets — not this one — and a hostless bundle has no host binary to
//  borrow their symbols from. Rather than fight the synchronized-folder model
//  with fragile explicit file references, this one translation unit #includes the
//  three .m files (a "unity" include). Their headers are found via the test
//  target's HEADER_SEARCH_PATHS (ES_Archive, ES_Archive/Server, ES_Archive/Stdio).
//
//  Keep this the ONLY place that includes these .m files, so each @implementation
//  is compiled exactly once — no duplicate symbols.
//

#import "../ES_Archive/Server/ESEngineSocket.m"
#import "../ES_Archive/Server/MCPUnixSocketServer.m"
#import "../ES_Archive/Stdio/MCPSocketClient.m"
