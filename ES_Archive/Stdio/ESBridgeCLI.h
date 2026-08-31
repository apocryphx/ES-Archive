//
//  ESBridgeCLI.h
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Pipeline interpreter for archive_cli, hosted in the stdio transport.
//
//  The CLI is composition logic — it has no business in the data engine.
//  It is the cognitive layer between Claude and the engine's per-tool MCP
//  surface: it parses a pipeline expression and drives the engine's
//  archive_pipeline tool. The engine keeps its original API; this layer does
//  the Unix-style composition work and presents archive_cli as a single tool
//  to the LLM.
//
//  Carried over from ES-Memory-Bridge; the only change is the execution
//  seam — stages run against the in-process ESEngine instead of an HTTP
//  forward to a separate host app.
//
//  Architecture:
//    Claude ──stdio──> archive_cli  ──in-process──> engine.archive_pipeline
//    (sees one tool)   (parses pipeline,           (per-tool MCP surface)
//                       composes results)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Tokenization

/// One token from shell-style lexing. Either a word (possibly quoted) or
/// the pipe operator. Preserves quoted-ness so the parser knows whether
/// "head" was a literal value or a command name.
@interface ESBridgeCLIToken : NSObject
@property (nonatomic, readonly) NSString *value;
@property (nonatomic, readonly) BOOL isPipe;
@property (nonatomic, readonly) BOOL wasQuoted;
@end

/// Tokenize a pipeline expression. Handles double-quoted strings (preserving
/// internal spaces and `\"`/`\\` backslash escapes), single-quoted strings
/// (literal, no escapes), bare words, and the `|` operator outside quotes.
/// Returns nil and populates *errorOut on syntax errors (unterminated quotes).
NSArray<ESBridgeCLIToken *> * _Nullable
ESBridgeCLITokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut);

#pragma mark - Parsed pipeline shape

/// One command invocation parsed from tokens. e.g. "lfind --tag 'X' --days 7"
/// becomes name="lfind", positional=[], flags={"tag":"X", "days":"7"}.
/// Boolean flags ("--regex" with no value before the next flag) become @YES.
@interface ESBridgeCLIStage : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSArray<NSString *> *positional;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *flags;
@end

/// Parse a flat token list into ordered stages. Returns nil and populates
/// *errorOut on structural errors (empty stage, dangling pipe, unknown flag
/// syntax).
NSArray<ESBridgeCLIStage *> * _Nullable
ESBridgeCLIParseStages(NSArray<ESBridgeCLIToken *> *tokens,
                       NSError * _Nullable * _Nullable errorOut);

#pragma mark - Engine tool calls (declared here so command handlers can call it)

/// Wraps a tools/call JSON-RPC envelope around the (toolName, arguments)
/// pair, hands it to ESEngine, parses the response, and returns the inner
/// tool-result dict.
///
/// On dispatch failure, JSON parse failure, or unexpected response shape:
/// returns nil and populates *errorOut. The caller must handle that.
NSDictionary * _Nullable
ESBridgeCallTool(NSString *toolName,
                 NSDictionary *arguments,
                 NSError * _Nullable * _Nullable errorOut);

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

#pragma mark - Execution

/// Execute a parsed pipeline. Returns the response dictionary that
/// archive_cli should serialize.
///
/// Response shape on success:
///   {
///     "pipeline":  "lfind --tag X         → 11 hits\n"
///                  "| w2vgrep \"y\"        → 11 hits  (re-rank only)\n"
///                  "| head 5               → 5 hits",
///     "results":   [ {title, score?, summary?}, ... ]
///   }
///
/// On error:
///   { "error": "...", "message": "...", "pipeline": "..." }
NSDictionary *
ESBridgeCLIExecute(NSArray<ESBridgeCLIStage *> *stages);

NS_ASSUME_NONNULL_END
