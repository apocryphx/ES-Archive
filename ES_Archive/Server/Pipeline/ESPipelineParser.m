//
//  ESPipelineParser.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESPipelineParser.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const ESPipelineParseErrorDomain = @"ESPipelineParseError";

static NSError *ParseError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:ESPipelineParseErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - ESPipelineToken

@implementation ESPipelineToken {
    NSString *_value;
    BOOL _isPipe;
    BOOL _wasQuoted;
}

- (instancetype)initWithValue:(NSString *)value pipe:(BOOL)isPipe quoted:(BOOL)wasQuoted {
    self = [super init];
    if (self) {
        _value = [value copy];
        _isPipe = isPipe;
        _wasQuoted = wasQuoted;
    }
    return self;
}

- (NSString *)value     { return _value; }
- (BOOL)isPipe          { return _isPipe; }
- (BOOL)wasQuoted       { return _wasQuoted; }

- (NSString *)description {
    if (_isPipe) return @"|";
    return _wasQuoted ? [NSString stringWithFormat:@"\"%@\"", _value] : _value;
}

@end

#pragma mark - Tokenizer

// Shell-style tokenizer. Three states:
//   - default: read bare words, treat `|` as a separator, treat `"` and `'` as quote-open
//   - in_double_quote: read until matching `"`, honor `\"` and `\\` escapes
//   - in_single_quote: read literally until matching `'`, no escapes (Bourne shell)
// Whitespace separates tokens outside quotes; preserved inside.
NSArray<ESPipelineToken *> * _Nullable
ESPipelineTokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut) {
    if (!expression) {
        if (errorOut) *errorOut = ParseError(1, @"empty expression");
        return nil;
    }

    NSMutableArray<ESPipelineToken *> *tokens = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL hasContent = NO;
    BOOL wasQuoted = NO;
    enum { kDefault, kInDouble, kInSingle } state = kDefault;

    NSUInteger i = 0;
    NSUInteger len = expression.length;

    while (i < len) {
        unichar c = [expression characterAtIndex:i];

        if (state == kDefault) {
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) {
                if (hasContent) {
                    [tokens addObject:[[ESPipelineToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                i++;
                continue;
            }
            if (c == '|') {
                if (hasContent) {
                    [tokens addObject:[[ESPipelineToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                [tokens addObject:[[ESPipelineToken alloc] initWithValue:@"|" pipe:YES quoted:NO]];
                i++;
                continue;
            }
            if (c == '"') {
                state = kInDouble;
                wasQuoted = YES;
                hasContent = YES;
                i++;
                continue;
            }
            if (c == '\'') {
                state = kInSingle;
                wasQuoted = YES;
                hasContent = YES;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            hasContent = YES;
            i++;
            continue;
        }

        if (state == kInDouble) {
            if (c == '\\' && i + 1 < len) {
                unichar next = [expression characterAtIndex:i + 1];
                if (next == '"' || next == '\\') {
                    [current appendFormat:@"%C", next];
                    i += 2;
                    continue;
                }
            }
            if (c == '"') {
                state = kDefault;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }

        if (state == kInSingle) {
            if (c == '\'') {
                state = kDefault;
                i++;
                continue;
            }
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }
    }

    if (state != kDefault) {
        if (errorOut) {
            NSString *msg = (state == kInDouble)
                ? @"unterminated double quote"
                // Bourne-shell single quotes are literal — they don't accept
                // any escape, so titles containing apostrophes (e.g.
                // "Claude's Notes") must use double quotes. Tell the user.
                : @"unterminated single quote — single quotes don't allow embedded apostrophes; "
                  @"for titles like Claude's Notes, use double quotes: cat \"Claude's Notes\"";
            *errorOut = ParseError(2, msg);
        }
        return nil;
    }

    if (hasContent) {
        [tokens addObject:[[ESPipelineToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
    }
    return tokens;
}

#pragma mark - Parser

NSArray<NSDictionary *> * _Nullable
ESPipelineParseStages(NSArray<ESPipelineToken *> *tokens,
                      NSError * _Nullable * _Nullable errorOut) {
    NSMutableArray<NSDictionary *> *stages = [NSMutableArray array];
    NSUInteger i = 0;
    NSUInteger n = tokens.count;

    if (n == 0) {
        if (errorOut) *errorOut = ParseError(3, @"empty pipeline");
        return nil;
    }

    // Flags that never take a value. Without this, the parser's greedy
    // "next token is the value" lookahead would eat the positional argument
    // when a boolean flag appears before it — e.g. `grep --attachments
    // "pattern"` would parse as flags={attachments: "pattern"} with
    // positional empty, and the filter would error "grep requires a
    // pattern."
    //
    // Hardcoded list rather than per-filter declaration so this parser stays
    // decoupled from the filter classes' compile-time surface. When you add
    // a new boolean-only flag to a filter, add its name here.
    static NSSet<NSString *> *booleanOnlyFlags;
    static dispatch_once_t booleanOnce;
    dispatch_once(&booleanOnce, ^{
        booleanOnlyFlags = [NSSet setWithArray:@[
            @"regex",
            @"case-sensitive",
            @"attachments",
            @"body",
            @"title",
            @"include-expired",
        ]];
    });

    while (i < n) {
        if (tokens[i].isPipe) {
            if (errorOut) *errorOut = ParseError(4, @"empty stage (pipe with nothing on the left)");
            return nil;
        }

        ESPipelineToken *nameTok = tokens[i++];
        NSString *name = nameTok.value;
        if ([name hasPrefix:@"--"]) {
            if (errorOut) {
                *errorOut = ParseError(5, [NSString stringWithFormat:
                                           @"expected command name, got flag %@", name]);
            }
            return nil;
        }

        NSMutableArray<NSString *> *positional = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *flags = [NSMutableDictionary dictionary];

        while (i < n && !tokens[i].isPipe) {
            ESPipelineToken *tok = tokens[i];
            if (!tok.wasQuoted && [tok.value hasPrefix:@"--"]) {
                NSString *flagName = [tok.value substringFromIndex:2];
                if (flagName.length == 0) {
                    if (errorOut) *errorOut = ParseError(6, @"empty flag name (--)");
                    return nil;
                }
                i++;
                // Boolean-only flags never consume the next token.
                if ([booleanOnlyFlags containsObject:flagName]) {
                    flags[flagName] = @YES;
                    continue;
                }
                if (i >= n || tokens[i].isPipe ||
                    (!tokens[i].wasQuoted && [tokens[i].value hasPrefix:@"--"])) {
                    flags[flagName] = @YES;
                    continue;
                }
                flags[flagName] = tokens[i].value;
                i++;
                continue;
            }
            [positional addObject:tok.value];
            i++;
        }

        // Same marshalled shape the stdio bridge used to hand archive_pipeline:
        // optional keys are omitted when empty.
        NSMutableDictionary *stage = [NSMutableDictionary dictionaryWithCapacity:3];
        stage[@"name"] = name;
        if (positional.count > 0) stage[@"positional"] = [positional copy];
        if (flags.count > 0)      stage[@"flags"]      = [flags copy];
        [stages addObject:[stage copy]];

        if (i < n && tokens[i].isPipe) i++;
    }

    return stages;
}

NSArray<NSDictionary *> * _Nullable
ESPipelineParseExpression(NSString *expression, NSError * _Nullable * _Nullable errorOut) {
    NSArray<ESPipelineToken *> *tokens = ESPipelineTokenize(expression, errorOut);
    if (!tokens) return nil;
    return ESPipelineParseStages(tokens, errorOut);
}

NS_ASSUME_NONNULL_END
