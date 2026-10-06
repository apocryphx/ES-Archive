//
//  ESBridgeCLI.m
//  ES Archive MCP
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESBridgeCLI.h"
#import "ESBridgeCLI.h"


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

