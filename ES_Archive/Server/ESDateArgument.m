//
//  ESDateArgument.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESDateArgument.h"

NS_ASSUME_NONNULL_BEGIN

// Parse one of "+N <unit>", "-N <unit>", or compact "+1d"/"-2h" into a
// signed number of seconds. Returns NO if the input doesn't match.
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

    // Months and years are calendar-aware in principle, but for tag
    // lifecycles and backdated entries a 30-day / 365-day approximation is
    // fine, and seconds-based arithmetic is stable across locales.
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

NSDate * _Nullable ESDateFromArgument(NSString * _Nullable input) {
    if (![input isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [input stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;

    // Absolute ISO-8601 first: it is the canonical form, and a "+0500"
    // timezone suffix must keep its meaning rather than read as an offset.
    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    NSDate *absolute = [df dateFromString:trimmed];
    if (absolute) return absolute;

    NSInteger seconds = 0;
    if (ParseRelativeOffset(trimmed, &seconds)) {
        return [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)seconds];
    }
    return nil;
}

NSString *ESDateArgumentHint(void) {
    return @"Provide ISO-8601 (e.g. 2026-06-01T12:00:00Z) or a relative offset "
            "like \"+30 days\", \"-1 hour\", \"+2h\".";
}

NS_ASSUME_NONNULL_END
