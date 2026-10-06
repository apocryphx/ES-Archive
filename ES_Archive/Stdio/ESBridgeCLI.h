//
//  ESBridgeCLI.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  What is left of the stdio bridge's transport-side helpers.
//
//  This file used to hold the archive_cli pipeline interpreter (tokenizer,
//  stage parser, executor). That moved into the engine as
//  Server/Pipeline/ESPipelineParser and the engine-side archive_cli tool
//  (Server/Tools/ESMemoryCLITool), so the string grammar is served on every
//  surface — see design-decisions/pipeline-unification.md. archive_cli is
//  now an ordinary engine tool call from the stdio host's point of view.
//
//  What remains is the relative-date normalizer, which the stdio host still
//  applies to date arguments before dispatch (phase 2 of the same brief
//  moves it engine-side too).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Date helpers

/// Accepts an absolute ISO-8601 datetime, or a relative offset of the form
/// "+N <unit>" / "-N <unit>" / compact "+1d" / "-2h". Units: s, m, h, d, w
/// (and longer spellings like "days", "hours", "weeks"). Returns the
/// resolved absolute datetime as an ISO-8601 string. Returns nil on
/// unrecognized input.
///
/// The transport uses this to make tag-lifecycle tool calls ergonomic:
/// Claude can write expiresAt="+30 days" and the engine still receives
/// a strict ISO-8601 timestamp.
NSString * _Nullable
ESBridgeNormalizeRelativeDate(NSString *input);

NS_ASSUME_NONNULL_END
