//
//  ESGrepFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESGrepFilter.h"
#import "ESPipelineDiagnostic.h"
#import "CDMemory.h"
#import "CDReference.h"

@implementation ESGrepFilter {
    NSString *_pattern;
    BOOL _useRegex;
    BOOL _caseSensitive;
    NSString *_scope;
    NSString * _Nullable _breHint;     // diagnostic annotation if pattern looks BRE
    ESPipelineStage *_stage;
}

+ (NSString *)commandName { return @"grep"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _pattern = stage.positional.firstObject;
        if (_pattern.length == 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"grep requires a pattern — try: grep \"...\""}];
            }
            return nil;
        }

        id regexVal = stage.flags[@"regex"];
        _useRegex = ([regexVal isKindOfClass:NSNumber.class] && [regexVal boolValue]);

        id csVal = stage.flags[@"case-sensitive"];
        _caseSensitive = ([csVal isKindOfClass:NSNumber.class] && [csVal boolValue]);

        // Scope: --scope all|title|body. Also accept the bare-flag synonyms
        // --title, --body, which read more naturally ("grep X --title" vs
        // "grep X --scope title") and match what users instinctively reach for.
        id scopeVal = stage.flags[@"scope"];
        if ([scopeVal isKindOfClass:NSString.class] && [(NSString *)scopeVal length] > 0) {
            _scope = (NSString *)scopeVal;
        } else if ([stage.flags[@"title"] boolValue]) {
            _scope = @"title";
        } else if ([stage.flags[@"body"] boolValue]) {
            _scope = @"body";
        } else {
            _scope = @"all";
        }

        // BRE-escape detection. Patterns like "pinhole\|confocal" silently
        // return 0 results in both modes:
        //   - without --regex: searched as literal "pinhole\|confocal", no hits
        //   - with --regex: ICU treats \| as literal | (escaping a non-special
        //     char yields the literal), so the regex matches the substring
        //     "pinhole|confocal" — also no hits
        // The man page documents this, but the failure is silent at runtime.
        // Surface it inline in the pipeline diagnostic instead — same approach
        // as w2vgrep's "short query unreliable, use grep" annotation. Detect
        // the escape sequences a BRE-trained user is most likely to reach for;
        // skip detection when the pattern doesn't contain a backslash at all
        // (overwhelmingly the common case).
        if ([_pattern containsString:@"\\"]) {
            NSString *found = nil;
            if      ([_pattern rangeOfString:@"\\|"].location != NSNotFound) found = @"|";
            else if ([_pattern rangeOfString:@"\\("].location != NSNotFound) found = @"(";
            else if ([_pattern rangeOfString:@"\\)"].location != NSNotFound) found = @")";
            else if ([_pattern rangeOfString:@"\\+"].location != NSNotFound) found = @"+";
            else if ([_pattern rangeOfString:@"\\?"].location != NSNotFound) found = @"?";
            else if ([_pattern rangeOfString:@"\\{"].location != NSNotFound) found = @"{";
            else if ([_pattern rangeOfString:@"\\}"].location != NSNotFound) found = @"}";
            if (found) {
                _breHint = _useRegex
                    ? [NSString stringWithFormat:
                        @"BRE escape — ICU regex uses bare %@", found]
                    : [NSString stringWithFormat:
                        @"BRE escape — needs --regex, and bare %@ in ICU", found];
            }
        }
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    NSString *effectivePattern = _useRegex
        ? _pattern
        : [NSRegularExpression escapedPatternForString:_pattern];

    NSRegularExpressionOptions opts = 0;
    if (!_caseSensitive) opts |= NSRegularExpressionCaseInsensitive;

    NSError *regexErr = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:effectivePattern
                                                                            options:opts
                                                                              error:&regexErr];
    if (!regex) {
        if (errOut) *errOut = regexErr;
        return @[];
    }

    BOOL includeTitle = [_scope isEqualToString:@"all"] || [_scope isEqualToString:@"title"];
    BOOL includeBody = [_scope isEqualToString:@"all"] || [_scope isEqualToString:@"body"];

    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"CDMemory"];
    fetch.includesSubentities = NO;
    if (prior) {
        fetch.predicate = [NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]];
    }
    fetch.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"dateModified" ascending:NO]];

    NSError *fetchErr = nil;
    NSArray<CDMemory *> *candidates = [ctx executeFetchRequest:fetch error:&fetchErr];
    if (fetchErr) {
        if (errOut) *errOut = fetchErr;
        return @[];
    }

    NSMutableArray<NSManagedObjectID *> *hits = [NSMutableArray array];
    for (CDMemory *m in candidates) {
        BOOL matched = NO;
        if (includeTitle && m.title.length > 0) {
            NSUInteger n = [regex numberOfMatchesInString:m.title
                                                  options:0
                                                    range:NSMakeRange(0, m.title.length)];
            if (n > 0) matched = YES;
        }
        if (!matched && includeBody && m.body.length > 0) {
            NSUInteger n = [regex numberOfMatchesInString:m.body
                                                  options:0
                                                    range:NSMakeRange(0, m.body.length)];
            if (n > 0) matched = YES;
        }
        if (matched) [hits addObject:m.objectID];
    }
    return hits;
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    if (_breHint) {
        // Same shape as w2vgrep's bracket annotation. Putting the hint at the
        // point of failure beats burying it in the man page — a user who
        // typed `grep "pinhole\|confocal" | head 5` sees the warning AND
        // their result count on the same diagnostic line.
        spelling = [NSString stringWithFormat:@"%@ [%@]", spelling, _breHint];
    }
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindFilter);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    grep — literal or regex pattern match across entry text\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    grep \"pattern\" [--title | --body | --scope KIND]\n"
        @"                  [--regex] [--case-sensitive]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Pattern search across entry text. By default, searches the\n"
        @"    entry's title and body. Returns entries with at least one\n"
        @"    match — the result is a population of entry IDs that downstream\n"
        @"    stages can refine.\n"
        @"\n"
        @"    --title         Search only entry titles. Useful when the title\n"
        @"                    is the most disambiguating field — `grep \"Flame\n"
        @"                    Spiral\" --title` cleanly finds the named entry\n"
        @"                    without the noise of every body that mentions\n"
        @"                    flames or spirals. Equivalent to --scope title.\n"
        @"    --body          Search only entry bodies (skip the title).\n"
        @"                    Equivalent to --scope body.\n"
        @"    --scope KIND    Narrow form taking all|title|body. Default: all.\n"
        @"    --regex         Treat pattern as ICU regex. Without this flag,\n"
        @"                    the pattern is matched as a literal substring\n"
        @"                    (regex metacharacters are escaped). Required\n"
        @"                    for ANY regex feature, including alternation.\n"
        @"                    Flavor is ICU/PCRE-style — bare metacharacters,\n"
        @"                    NOT sed/grep BRE:\n"
        @"                        alternation:  \"foo|bar\"   (NOT \"foo\\|bar\")\n"
        @"                        groups:       \"(foo|bar)\" (NOT \"\\(foo\\|bar\\)\")\n"
        @"                        repetition:   \"a+\"        (NOT \"a\\+\")\n"
        @"    --case-sensitive  Default is case-insensitive.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Find every mention across titles and bodies:\n"
        @"        grep \"FSEvents\"\n"
        @"\n"
        @"    Find an entry by title fragment (most disambiguating):\n"
        @"        grep \"Flame Spiral\" --title\n"
        @"\n"
        @"    Pattern within a tag scope:\n"
        @"        lfind --tag \"ES Archive\" | grep \"NSCache\" | head 5\n"
        @"\n"
        @"    Title matches X AND body matches Y:\n"
        @"        grep \"X\" --title | grep \"Y\" --body | head 5\n"
        @"\n"
        @"    Regex alternation (note bare |, NOT \\|):\n"
        @"        grep \"Future Signal|CDForesight\" --regex | head 5\n"
        @"\n"
        @"DIAGNOSTICS\n"
        @"    [BRE escape — ICU regex uses bare X]\n"
        @"        Inline hint when the pattern contains a BRE-style escape\n"
        @"        like \\|, \\(, \\), \\+, \\?, \\{, \\} that doesn't do what\n"
        @"        BRE-trained users expect. ICU treats these as literal\n"
        @"        characters, not metacharacters — so `grep \"a\\|b\" --regex`\n"
        @"        silently matches the literal string \"a|b\" rather than\n"
        @"        alternating. The hint shows up regardless of result count\n"
        @"        because the pattern is almost certainly a bug whether it\n"
        @"        finds zero hits or accidentally finds one.\n"
        @"    [BRE escape — needs --regex, and bare X in ICU]\n"
        @"        Same detection without --regex. The pattern is then matched\n"
        @"        as literal substring (with the backslash treated literally),\n"
        @"        which won't find anything either. Two fixes needed: add\n"
        @"        --regex AND switch to bare ICU metacharacters.\n"
        @"\n"
        @"SEE ALSO\n"
        @"    w2vgrep, lfind\n";
}

@end
