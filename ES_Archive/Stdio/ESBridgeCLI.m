//
//  ESBridgeCLI.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESBridgeCLI.h"
#import "ESEngine.h"
#import <stdatomic.h>

#pragma mark - Date helpers

// Parse one of "+N <unit>", "-N <unit>", or compact "+1d"/"-2h" into a
// (sign, value, unit-key) triple. Returns NO if the input doesn't match.
static BOOL ParseRelativeOffset(NSString *input, NSInteger *outSeconds) {
    if (input.length < 2) return NO;
    unichar first = [input characterAtIndex:0];
    if (first != '+' && first != '-') return NO;
    NSInteger sign = (first == '+') ? 1 : -1;

    NSString *rest = [[input substringFromIndex:1]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (rest.length == 0) return NO;

    // Split number and unit. Number is the leading digit run.
    NSUInteger numEnd = 0;
    while (numEnd < rest.length &&
           [[NSCharacterSet decimalDigitCharacterSet]
            characterIsMember:[rest characterAtIndex:numEnd]]) {
        numEnd++;
    }
    if (numEnd == 0) return NO;
    NSInteger value = [[rest substringToIndex:numEnd] integerValue];
    NSString *unit = [[rest substringFromIndex:numEnd]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    unit = unit.lowercaseString;
    if (unit.length == 0) return NO;

    // Map unit spellings to seconds. Months and years are calendar-aware in
    // principle, but for tag lifecycles "30 days" approximations are fine —
    // we want NSDate arithmetic that's stable across locales, so seconds-
    // based works.
    NSInteger unitSeconds = 0;
    if ([@[@"s", @"sec", @"secs", @"second", @"seconds"] containsObject:unit]) {
        unitSeconds = 1;
    } else if ([@[@"m", @"min", @"mins", @"minute", @"minutes"] containsObject:unit]) {
        unitSeconds = 60;
    } else if ([@[@"h", @"hr", @"hrs", @"hour", @"hours"] containsObject:unit]) {
        unitSeconds = 60 * 60;
    } else if ([@[@"d", @"day", @"days"] containsObject:unit]) {
        unitSeconds = 60 * 60 * 24;
    } else if ([@[@"w", @"wk", @"week", @"weeks"] containsObject:unit]) {
        unitSeconds = 60 * 60 * 24 * 7;
    } else if ([@[@"mo", @"month", @"months"] containsObject:unit]) {
        unitSeconds = 60 * 60 * 24 * 30;
    } else if ([@[@"y", @"yr", @"year", @"years"] containsObject:unit]) {
        unitSeconds = 60 * 60 * 24 * 365;
    } else {
        return NO;
    }

    if (outSeconds) *outSeconds = sign * value * unitSeconds;
    return YES;
}

NSString * _Nullable ESBridgeNormalizeRelativeDate(NSString *input) {
    if (![input isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [input stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length == 0) return nil;

    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];

    // Try ISO-8601 absolute first — it's the canonical form, and we want
    // "+0500" or similar valid timezone offsets to keep their meaning.
    NSDate *absolute = [df dateFromString:trimmed];
    if (absolute) return [df stringFromDate:absolute];

    // Fall through to relative-offset parsing.
    NSInteger seconds = 0;
    if (ParseRelativeOffset(trimmed, &seconds)) {
        NSDate *resolved = [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)seconds];
        return [df stringFromDate:resolved];
    }

    return nil;
}

#pragma mark - ESBridgeCLIToken

@implementation ESBridgeCLIToken {
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
NSArray<ESBridgeCLIToken *> * _Nullable
ESBridgeCLITokenize(NSString *expression, NSError * _Nullable * _Nullable errorOut) {
    if (!expression) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty expression"}];
        }
        return nil;
    }

    NSMutableArray<ESBridgeCLIToken *> *tokens = [NSMutableArray array];
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
                    [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                i++;
                continue;
            }
            if (c == '|') {
                if (hasContent) {
                    [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
                    [current setString:@""];
                    hasContent = NO;
                    wasQuoted = NO;
                }
                [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:@"|" pipe:YES quoted:NO]];
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
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:2
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }

    if (hasContent) {
        [tokens addObject:[[ESBridgeCLIToken alloc] initWithValue:current pipe:NO quoted:wasQuoted]];
    }
    return tokens;
}

#pragma mark - ESBridgeCLIStage

@implementation ESBridgeCLIStage {
    NSString *_name;
    NSArray<NSString *> *_positional;
    NSDictionary<NSString *, id> *_flags;
}

- (instancetype)initWithName:(NSString *)name
                   positional:(NSArray<NSString *> *)positional
                        flags:(NSDictionary<NSString *, id> *)flags {
    self = [super init];
    if (self) {
        _name = [name copy];
        _positional = [positional copy];
        _flags = [flags copy];
    }
    return self;
}

- (NSString *)name                              { return _name; }
- (NSArray<NSString *> *)positional             { return _positional; }
- (NSDictionary<NSString *, id> *)flags         { return _flags; }

- (NSString *)description {
    NSMutableString *s = [NSMutableString stringWithString:_name];
    for (NSString *p in _positional) {
        if ([p rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
            [s appendFormat:@" \"%@\"", p];
        } else {
            [s appendFormat:@" %@", p];
        }
    }
    [_flags enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if ([v isKindOfClass:NSNumber.class] && [v boolValue]) {
            [s appendFormat:@" --%@", k];
        } else {
            NSString *vs = [NSString stringWithFormat:@"%@", v];
            if ([vs rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) {
                [s appendFormat:@" --%@ \"%@\"", k, vs];
            } else {
                [s appendFormat:@" --%@ %@", k, vs];
            }
        }
    }];
    return s;
}

@end

#pragma mark - Parser

NSArray<ESBridgeCLIStage *> * _Nullable
ESBridgeCLIParseStages(NSArray<ESBridgeCLIToken *> *tokens,
                       NSError * _Nullable * _Nullable errorOut) {
    NSMutableArray<ESBridgeCLIStage *> *stages = [NSMutableArray array];
    NSUInteger i = 0;
    NSUInteger n = tokens.count;

    if (n == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty pipeline"}];
        }
        return nil;
    }

    while (i < n) {
        if (tokens[i].isPipe) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:4
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                @"empty stage (pipe with nothing on the left)"}];
            }
            return nil;
        }

        ESBridgeCLIToken *nameTok = tokens[i++];
        NSString *name = nameTok.value;
        if ([name hasPrefix:@"--"]) {
            if (errorOut) {
                *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:5
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"expected command name, got flag %@", name]}];
            }
            return nil;
        }

        NSMutableArray<NSString *> *positional = [NSMutableArray array];
        NSMutableDictionary<NSString *, id> *flags = [NSMutableDictionary dictionary];

        // Flags that never take a value. Without this, the parser's
        // greedy "next token is the value" lookahead would eat the
        // positional argument when a boolean flag appears before it
        // — e.g. `grep --attachments "pattern"` would parse as
        // flags={attachments: "pattern"} with positional empty,
        // and the filter would error "grep requires a pattern."
        //
        // Hardcoded list rather than per-filter declaration so this
        // parser stays decoupled from the filter classes' compile-time
        // surface. When you add a new boolean-only flag to a filter,
        // add its name here.
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

        while (i < n && !tokens[i].isPipe) {
            ESBridgeCLIToken *tok = tokens[i];
            if (!tok.wasQuoted && [tok.value hasPrefix:@"--"]) {
                NSString *flagName = [tok.value substringFromIndex:2];
                if (flagName.length == 0) {
                    if (errorOut) {
                        *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:6
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                                        @"empty flag name (--)"}];
                    }
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

        [stages addObject:[[ESBridgeCLIStage alloc] initWithName:name positional:positional flags:flags]];

        if (i < n && tokens[i].isPipe) i++;
    }

    return stages;
}

#pragma mark - Engine tool calls

NSDictionary * _Nullable
ESBridgeCallTool(NSString *toolName,
                 NSDictionary *arguments,
                 NSError * _Nullable * _Nullable errorOut) {
    // Atomic so concurrent archive_cli pipelines (running on MCPStdioServer's
    // concurrent work queue) can't collide on the same JSON-RPC id in logs.
    static _Atomic NSInteger nextId = 1000;
    NSInteger thisId = atomic_fetch_add(&nextId, 1) + 1;

    NSDictionary *envelope = @{
        @"jsonrpc": @"2.0",
        @"id":      @(thisId),
        @"method":  @"tools/call",
        @"params":  @{
            @"name":      toolName,
            @"arguments": arguments ?: @{}
        }
    };

    NSDictionary *responseDict = [ESEngine.shared handleRequest:envelope];
    if (![responseDict isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:11
                                         userInfo:@{NSLocalizedDescriptionKey: @"no response from engine"}];
        }
        return nil;
    }

    // Surface MCP-level errors to the caller.
    NSDictionary *mcpError = responseDict[@"error"];
    if ([mcpError isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            NSString *msg = mcpError[@"message"] ?: @"engine error";
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIServerError" code:13
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }

    NSDictionary *result = responseDict[@"result"];
    if (![result isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:14
                                         userInfo:@{NSLocalizedDescriptionKey: @"missing result in response"}];
        }
        return nil;
    }

    NSArray *content = result[@"content"];
    if (![content isKindOfClass:NSArray.class] || content.count == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:15
                                         userInfo:@{NSLocalizedDescriptionKey: @"empty content array"}];
        }
        return nil;
    }

    NSDictionary *first = content[0];
    NSString *text = first[@"text"];
    if (![text isKindOfClass:NSString.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:16
                                         userInfo:@{NSLocalizedDescriptionKey: @"missing text in content"}];
        }
        return nil;
    }

    NSData *innerData = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *inner = [NSJSONSerialization JSONObjectWithData:innerData options:0 error:nil];
    if (![inner isKindOfClass:NSDictionary.class]) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"ESBridgeCLIError" code:17
                                         userInfo:@{NSLocalizedDescriptionKey: @"inner result is not a dict"}];
        }
        return nil;
    }

    return inner;
}

#pragma mark - Execution

// Strip "uuid" fields from any results array in the response. The transport↔
// engine protocol carries UUIDs (for graph analysis tools, scripts, etc),
// but Claude shouldn't see them — UUIDs are machine identity, titles are
// reading interface. Mixing them in the same response degrades the
// LLM-facing surface for an audience that doesn't need machine identity.
static NSDictionary *StripUUIDsFromResponse(NSDictionary *response) {
    if (![response isKindOfClass:NSDictionary.class]) return response;
    NSArray *results = response[@"results"];
    if (![results isKindOfClass:NSArray.class]) return response;

    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:results.count];
    for (NSDictionary *row in results) {
        if (![row isKindOfClass:NSDictionary.class]) {
            [cleaned addObject:row];
            continue;
        }
        if (row[@"uuid"]) {
            NSMutableDictionary *copy = [row mutableCopy];
            [copy removeObjectForKey:@"uuid"];
            [cleaned addObject:[copy copy]];
        } else {
            [cleaned addObject:row];
        }
    }
    NSMutableDictionary *out = [response mutableCopy];
    out[@"results"] = cleaned;
    return [out copy];
}

NSDictionary *
ESBridgeCLIExecute(NSArray<ESBridgeCLIStage *> *stages) {
    if (stages.count == 0) {
        return @{
            @"error":   @"empty_pipeline",
            @"message": @"No commands. Try 'man' to see what's available.",
        };
    }

    // Marshal each stage to a {name, positional, flags} dict. The engine's
    // archive_pipeline tool deserializes this and instantiates the matching
    // ESPipelineFilter classes.
    NSMutableArray<NSDictionary *> *stageDicts = [NSMutableArray arrayWithCapacity:stages.count];
    for (ESBridgeCLIStage *stage in stages) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"name"] = stage.name;
        if (stage.positional.count > 0) d[@"positional"] = stage.positional;
        if (stage.flags.count > 0)      d[@"flags"]      = stage.flags;
        [stageDicts addObject:d];
    }

    NSError *err = nil;
    NSDictionary *response = ESBridgeCallTool(@"archive_pipeline",
                                              @{@"stages": stageDicts},
                                              &err);
    if (!response) {
        return @{
            @"error":   @"engine_call_failed",
            @"message": err.localizedDescription ?: @"archive_pipeline call failed",
        };
    }

    return StripUUIDsFromResponse(response);
}
