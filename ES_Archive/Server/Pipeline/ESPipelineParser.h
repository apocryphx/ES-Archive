//
//  ESPipelineParser.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  The archive_cli grammar, parsed engine-side.
//
//  `lfind --tag X | w2vgrep "…" | head 5` is the form every man page and
//  skill file teaches, so it has to be accepted on every surface — stdio and
//  HTTP alike. This parser turns that string into the stage array that
//  ESPipelineExecute already takes ({name, positional?, flags?}), so there
//  is exactly one grammar and no adapter. It moved here from the stdio
//  host's ESBridgeCLI (see design-decisions/pipeline-unification.md); the
//  grammar is unchanged byte for byte.
//
//  The parser knows nothing about authors or scope — that stays with the
//  executor.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for tokenizer and parser failures. The localized description
/// is the user-facing message (e.g. "unterminated double quote").
extern NSErrorDomain const ESPipelineParseErrorDomain;

#pragma mark - Tokenization

/// One token from shell-style lexing. Either a word (possibly quoted) or
/// the pipe operator. Preserves quoted-ness so the parser knows whether
/// "--tag" was a literal value or a flag.
@interface ESPipelineToken : NSObject
@property (nonatomic, readonly) NSString *value;
@property (nonatomic, readonly) BOOL isPipe;
@property (nonatomic, readonly) BOOL wasQuoted;
@end

/// Tokenize a pipeline expression. Handles double-quoted strings (preserving
/// internal spaces and `\"`/`\\` backslash escapes), single-quoted strings
/// (literal, no escapes), bare words, and the `|` operator outside quotes.
/// Returns nil and populates *errorOut on syntax errors (unterminated quotes).
NSArray<ESPipelineToken *> * _Nullable
ESPipelineTokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut);

#pragma mark - Parsing

/// Parse a flat token list into ordered stage dicts of shape
/// {name: string, positional: [string] (only if non-empty),
///  flags: {string: string|@YES} (only if non-empty)}.
/// e.g. "lfind --tag 'X' --days 7" → {name: "lfind", flags: {tag: "X", days: "7"}}.
/// Boolean flags ("--regex" with no value before the next flag) become @YES.
/// Returns nil and populates *errorOut on structural errors (empty pipeline,
/// empty stage, dangling pipe, flag where a command name was expected).
NSArray<NSDictionary *> * _Nullable
ESPipelineParseStages(NSArray<ESPipelineToken *> *tokens,
                      NSError * _Nullable * _Nullable errorOut);

/// Tokenize and parse in one step. This is what archive_cli and
/// archive_pipeline (with `expression`) call.
NSArray<NSDictionary *> * _Nullable
ESPipelineParseExpression(NSString *expression, NSError * _Nullable * _Nullable errorOut);

NS_ASSUME_NONNULL_END
