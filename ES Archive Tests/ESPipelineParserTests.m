//
//  ESPipelineParserTests.m
//  ES Archive Tests
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Grammar parity table for the engine-side archive_cli parser
//  (Server/Pipeline/ESPipelineParser). The expected stage shapes are what the
//  stdio bridge's ESBridgeCLI produced before the parser moved
//  (design-decisions/pipeline-unification.md §6) — the grammar must not drift.
//
//  The parser source is compiled into this hostless bundle by a unity include
//  below (same reason as ESUDSTransportUnderTest.m). Keep this the only place
//  that includes it.
//

#import <XCTest/XCTest.h>
#import "../ES_Archive/Server/Pipeline/ESPipelineParser.h"
#import "../ES_Archive/Server/Pipeline/ESPipelineParser.m"

@interface ESPipelineParserTests : XCTestCase
@end

@implementation ESPipelineParserTests

static NSArray *Parse(NSString *expr, NSError **err) {
    return ESPipelineParseExpression(expr, err);
}

- (void)testBareCommand {
    NSError *err = nil;
    NSArray *stages = Parse(@"man", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[ @{@"name": @"man"} ]));
}

- (void)testSingleQuotedFlagValueAndPositional {
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind --tag 'Isolde' | head 5", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"lfind", @"flags": @{@"tag": @"Isolde"}},
        @{@"name": @"head",  @"positional": @[@"5"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testDoubleQuotedValuesKeepSpacesAndCommas {
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind --tags \"Isolde, ES Archive\" | w2vgrep \"branching\" | head 5", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"lfind",   @"flags": @{@"tags": @"Isolde, ES Archive"}},
        @{@"name": @"w2vgrep", @"positional": @[@"branching"]},
        @{@"name": @"head",    @"positional": @[@"5"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testCuratorialChain {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep Isolde | grep Myth | tag 'Isoldes Stories'", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"grep", @"positional": @[@"Isolde"]},
        @{@"name": @"grep", @"positional": @[@"Myth"]},
        @{@"name": @"tag",  @"positional": @[@"Isoldes Stories"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testEscapedQuotesInsideDoubleQuotes {
    NSError *err = nil;
    NSArray *stages = Parse(@"w2vgrep \"a phrase with \\\"escaped\\\" quotes\" --focus week | head 3", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"w2vgrep", @"positional": @[@"a phrase with \"escaped\" quotes"],
          @"flags": @{@"focus": @"week"}},
        @{@"name": @"head", @"positional": @[@"3"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testEscapedBackslashInsideDoubleQuotes {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep \"a\\\\b\"", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[ @{@"name": @"grep", @"positional": @[@"a\\b"]} ]));
}

- (void)testSingleQuotesAreLiteral {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep 'a\\\"b'", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[ @{@"name": @"grep", @"positional": @[@"a\\\"b"]} ]));
}

- (void)testDiscoverModeAndQuotedPositional {
    NSError *err = nil;
    NSArray *stages = Parse(@"discover --mode forgotten | w2vgrep 'continuity' | head 10", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"discover", @"flags": @{@"mode": @"forgotten"}},
        @{@"name": @"w2vgrep",  @"positional": @[@"continuity"]},
        @{@"name": @"head",     @"positional": @[@"10"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testSortAndTail {
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind --days 7 | sort --by dateModified | tail 3", &err);
    XCTAssertNil(err);
    NSArray *expected = @[
        @{@"name": @"lfind", @"flags": @{@"days": @"7"}},
        @{@"name": @"sort",  @"flags": @{@"by": @"dateModified"}},
        @{@"name": @"tail",  @"positional": @[@"3"]},
    ];
    XCTAssertEqualObjects(stages, expected);
}

- (void)testBooleanOnlyFlagDoesNotEatPositional {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep --attachments \"pattern\"", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[
        @{@"name": @"grep", @"positional": @[@"pattern"], @"flags": @{@"attachments": @YES}}
    ]));
}

- (void)testTrailingFlagIsBoolean {
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind --tag X --something | head 2", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[
        @{@"name": @"lfind", @"flags": @{@"tag": @"X", @"something": @YES}},
        @{@"name": @"head",  @"positional": @[@"2"]},
    ]));
}

- (void)testFlagFollowedByFlagIsBoolean {
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind --foo --tag X", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[
        @{@"name": @"lfind", @"flags": @{@"foo": @YES, @"tag": @"X"}}
    ]));
}

- (void)testQuotedDoubleDashIsAValueNotAFlag {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep \"--not-a-flag\"", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[ @{@"name": @"grep", @"positional": @[@"--not-a-flag"]} ]));
}

- (void)testPipeInsideQuotesIsLiteral {
    NSError *err = nil;
    NSArray *stages = Parse(@"grep \"a | b\" | head 1", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[
        @{@"name": @"grep", @"positional": @[@"a | b"]},
        @{@"name": @"head", @"positional": @[@"1"]},
    ]));
}

- (void)testTrailingPipeIsTolerated {
    // Inherited bridge behavior: a trailing `|` after the last stage parses
    // as that stage alone. Preserved, not endorsed.
    NSError *err = nil;
    NSArray *stages = Parse(@"lfind |", &err);
    XCTAssertNil(err);
    XCTAssertEqualObjects(stages, (@[ @{@"name": @"lfind"} ]));
}

#pragma mark - Errors

- (void)testUnterminatedDoubleQuote {
    NSError *err = nil;
    XCTAssertNil(Parse(@"grep \"open", &err));
    XCTAssertEqualObjects(err.domain, ESPipelineParseErrorDomain);
    XCTAssertEqualObjects(err.localizedDescription, @"unterminated double quote");
}

- (void)testUnterminatedSingleQuoteExplainsApostrophes {
    NSError *err = nil;
    XCTAssertNil(Parse(@"cat 'Claude's Notes'", &err));
    XCTAssertTrue([err.localizedDescription hasPrefix:@"unterminated single quote"]);
    XCTAssertTrue([err.localizedDescription containsString:@"use double quotes"]);
}

- (void)testLeadingPipeIsEmptyStage {
    NSError *err = nil;
    XCTAssertNil(Parse(@"| head 5", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"empty stage (pipe with nothing on the left)");
}

- (void)testDoublePipeIsEmptyStage {
    NSError *err = nil;
    XCTAssertNil(Parse(@"lfind || head 5", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"empty stage (pipe with nothing on the left)");
}

- (void)testEmptyStringIsEmptyPipeline {
    NSError *err = nil;
    XCTAssertNil(Parse(@"", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"empty pipeline");
}

- (void)testWhitespaceOnlyIsEmptyPipeline {
    NSError *err = nil;
    XCTAssertNil(Parse(@"   \n ", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"empty pipeline");
}

- (void)testFlagWhereCommandExpected {
    NSError *err = nil;
    XCTAssertNil(Parse(@"--tag X | head 5", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"expected command name, got flag --tag");
}

- (void)testEmptyFlagName {
    NSError *err = nil;
    XCTAssertNil(Parse(@"lfind -- X", &err));
    XCTAssertEqualObjects(err.localizedDescription, @"empty flag name (--)");
}

@end
