//
//  ESRelativeDateTests.m
//  ES Archive Tests
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Table test for the recall-age renderer (Server/ESRelativeDate): the
//  decaying ladder, the plural edge, the calendar fallbacks, and the
//  one-stamp-per-row rule with its two exceptions. Everything is computed
//  against a fixed "now", so the tests are deterministic.
//
//  Compiled into this hostless bundle by a unity include; keep this the
//  only place that includes the .m.
//

#import <XCTest/XCTest.h>
#import "../ES_Archive/Server/ESRelativeDate.h"
#import "../ES_Archive/Server/ESRelativeDate.m"

@interface ESRelativeDateTests : XCTestCase
@end

@implementation ESRelativeDateTests

// 2026-10-11T12:00:00Z
static NSDate *Now(void) { return [NSDate dateWithTimeIntervalSince1970:1791720000]; }
static NSDate *Ago(NSTimeInterval s) { return [Now() dateByAddingTimeInterval:-s]; }

#define H (3600.0)
#define D (86400.0)

#pragma mark - Ladder

- (void)testUnderAMinuteIsJustNow {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(0), Now()), @"just now");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(59), Now()), @"just now");
}

- (void)testMinutes {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(60), Now()), @"1 min ago");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(59 * 60 + 59), Now()), @"59 min ago");
}

- (void)testHoursUpToTwoDays {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(H), Now()), @"1 hour ago");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(2 * H), Now()), @"2 hours ago");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(27 * H + 1800), Now()), @"27 hours ago");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(47 * H + 3599), Now()), @"47 hours ago");
}

- (void)testDaysUpToAMonth {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(48 * H), Now()), @"2 days ago");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(29 * D + 3600), Now()), @"29 days ago");
}

- (void)testWithinAYearIsCalendarDay {
    // 30 days before 2026-10-11 is 2026-09-11.
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(30 * D), Now()), @"Sep 11");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(200 * D), Now()), @"Mar 25");
}

- (void)testOlderThanAYearIsMonthAndYear {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(365 * D), Now()), @"Oct 2025");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(800 * D), Now()), @"Aug 2024");
}

- (void)testFutureDateFallsBackToCalendar {
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(-3 * D), Now()), @"Oct 14");
    XCTAssertEqualObjects(ESRelativeDateDescription(Ago(-400 * D), Now()), @"Nov 2027");
}

#pragma mark - Stamp

- (void)testNeverEditedByCreated {
    NSDate *c = Ago(27 * H);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"created", c, c, [c dateByAddingTimeInterval:2], Now()),
                          @"created 27 hours ago");
}

- (void)testEditedByCreatedAppendsUpdate {
    NSDate *c = Ago(3 * D), *m = Ago(2 * H);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"created", c, c, m, Now()),
                          @"created 3 days ago, updated 2 hours ago");
}

- (void)testEditedInSameBucketDropsSecondStamp {
    // Created and edited 4 days ago, hours apart: both say "4 days ago".
    NSDate *c = Ago(4 * D + 6 * H), *m = Ago(4 * D + 1 * H);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"created", c, c, m, Now()),
                          @"created 4 days ago");
}

- (void)testEditedByModifiedIsOneStamp {
    NSDate *c = Ago(3 * D), *m = Ago(2 * H);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"updated", m, c, m, Now()),
                          @"updated 2 hours ago");
}

- (void)testNeverEditedByModifiedSaysCreated {
    NSDate *c = Ago(5 * D);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"updated", c, c, c, Now()),
                          @"created 5 days ago");
}

- (void)testByAccessedIsOneStampEvenWhenEdited {
    NSDate *c = Ago(3 * D), *m = Ago(2 * H), *a = Ago(600);
    XCTAssertEqualObjects(ESRelativeDateStamp(@"read", a, c, m, Now()),
                          @"read 10 min ago");
}

- (void)testNilAxisDateIsEmpty {
    XCTAssertEqualObjects(ESRelativeDateStamp(@"read", nil, Ago(D), Ago(D), Now()), @"");
}

@end
