//
//  ESMemoryMaintenanceTool.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_maintenance
//  The single surface through which Claude tends the archive at the system
//  level: working preferences (language, embedder), bulk operations
//  (reindex, backfill missing vectors), and live diagnostics (memory and
//  vector counts, pending work). Settings are the read/write subset; bulk
//  operations are the long-running verbs.
//
//  Conceptually: the archive belongs to Claude. This is Claude's control
//  panel. Per-call retrieval knobs (search focus / decayLevel) are
//  intentionally NOT here — they're parameters on the tool that uses
//  them, so each session decides them explicitly rather than inheriting
//  invisible state from a previous session.
//

#import <Foundation/Foundation.h>
#import "MCPToolDispatcher.h"
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESMemoryMaintenanceTool : NSObject <MCPTooling>

/// Reconcile duplicate CDEmbedder inventory rows (identifier-keyed), re-pointing
/// their vectors onto the survivor before deleting the emptied rows. Exposed so
/// ESDeduplicator can re-assert the embedder inventory as part of its vector
/// invariant heal. Returns counters including `rowsDeleted`.
+ (NSDictionary *)dedupeEmbedders;

@end

NS_ASSUME_NONNULL_END
