//
//  ESDateArgumentTests.m
//  ES Archive Tests
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Table test for the engine-side date argument resolver
//  (Server/ESDateArgument): absolute ISO-8601 passes through, relative
//  offsets resolve against now, everything else is rejected. The same
//  resolver serves dateCreated, expiresAt, newExpiresAt, from and to on
//  every surface, so the grammar here is the documented one.
//
//  Compiled into this hostless bundle by a unity include; keep this the
//  only place that includes the .m.
//

#import <XCTest/XCTest.h>
#import "../ES_Archive/Server/ESDateArgument.h"
#import "../ES_Archive/Server/ESDateArgument.m"

@interface ESDateArgumentTests : XCTestCase
@end

@implementation ESDateArgumentTests

// Relative offsets resolve against the clock at call time, so compare the
// resulting interval from now with a tolerance.
static void AssertOffset(NSString *input, NSTimeInterval expectedSeconds) {
    NSDate *d = ESDateFromArgument(input);
    XCTAssertNotNil(d, @"%@ should parse", input);
    if (!d) return;
    NSTimeInterval actual = [d timeIntervalSinceNow];
    XCTAssertEqualWithAccuracy(actual, expectedSeconds, 2.0, @"%@", input);
}

#pragma mark - Absolute

- (void)testAbsoluteISO8601Zulu {
    NSDate *d = ESDateFromArgument(@"2026-06-01T12:00:00Z");
    XCTAssertNotNil(d);
    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    XCTAssertEqualObjects([df stringFromDate:d], @"2026-06-01T12:00:00Z");
}

- (void)testAbsoluteISO8601WithOffsetKeepsItsMeaning {
    // "+0500" here is a timezone, not a relative offset.
    NSDate *d = ESDateFromArgument(@"2026-06-01T12:00:00+0500");
    XCTAssertNotNil(d);
    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    XCTAssertEqualObjects([df stringFromDate:d], @"2026-06-01T07:00:00Z");
}

- (void)testSurroundingWhitespaceIsTrimmed {
    XCTAssertNotNil(ESDateFromArgument(@"  2026-06-01T12:00:00Z \n"));
}

#pragma mark - Relative

- (void)testCompactUnits {
    AssertOffset(@"+1s",  1);
    AssertOffset(@"+5m",  5 * 60);
    AssertOffset(@"-2h",  -2 * 3600);
    AssertOffset(@"+1d",  86400);
    AssertOffset(@"-1w",  -7 * 86400);
    AssertOffset(@"+1mo", 30 * 86400);
    AssertOffset(@"+1y",  365 * 86400);
}

- (void)testSpelledUnitsWithSpace {
    AssertOffset(@"+30 days",   30 * 86400);
    AssertOffset(@"-1 hour",    -3600);
    AssertOffset(@"+2 weeks",   14 * 86400);
    AssertOffset(@"-3 minutes", -180);
    AssertOffset(@"+10 seconds", 10);
    AssertOffset(@"+1 month",   30 * 86400);
    AssertOffset(@"-2 years",   -2 * 365 * 86400);
}

- (void)testAbbreviatedUnits {
    AssertOffset(@"+1 sec",  1);
    AssertOffset(@"+1 min",  60);
    AssertOffset(@"+1 hr",   3600);
    AssertOffset(@"+1 wk",   7 * 86400);
    AssertOffset(@"+1 yr",   365 * 86400);
}

- (void)testUnitsAreCaseInsensitive {
    AssertOffset(@"+30 DAYS", 30 * 86400);
    AssertOffset(@"-2H",      -7200);
}

- (void)testSpaceAfterSign {
    AssertOffset(@"+ 30 days", 30 * 86400);
}

#pragma mark - Rejected

- (void)testRejectsNilEmptyAndWhitespace {
    XCTAssertNil(ESDateFromArgument(nil));
    XCTAssertNil(ESDateFromArgument(@""));
    XCTAssertNil(ESDateFromArgument(@"   "));
}

- (void)testRejectsBareNumberAndUnit {
    XCTAssertNil(ESDateFromArgument(@"30 days"), @"a sign is required");
    XCTAssertNil(ESDateFromArgument(@"30"));
}

- (void)testRejectsUnknownUnit {
    XCTAssertNil(ESDateFromArgument(@"+3 fortnights"));
}

- (void)testRejectsMissingNumberOrUnit {
    XCTAssertNil(ESDateFromArgument(@"+days"));
    XCTAssertNil(ESDateFromArgument(@"+30"));
    XCTAssertNil(ESDateFromArgument(@"+"));
}

- (void)testRejectsProse {
    XCTAssertNil(ESDateFromArgument(@"tomorrow"));
    XCTAssertNil(ESDateFromArgument(@"2026-06-01"), @"date-only is not accepted by the ISO formatter in use");
}

- (void)testHintIsStable {
    XCTAssertTrue([ESDateArgumentHint() containsString:@"ISO-8601"]);
    XCTAssertTrue([ESDateArgumentHint() containsString:@"+30 days"]);
}

@end
