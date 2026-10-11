//
//  ESRelativeDate.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESRelativeDate.h"

NS_ASSUME_NONNULL_BEGIN

// An edit this close to creation is the store itself finishing its write
// (dateModified is set on every save), not a revision worth a stamp.
static const NSTimeInterval kESRelativeDateEditThreshold = 60.0;

static NSDateFormatter *CalendarFormatter(NSString *format) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = format;
    return f;
}

static NSString *CalendarDescription(NSDate *date, BOOL withinYear) {
    static NSDateFormatter *dayFmt, *monthFmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dayFmt   = CalendarFormatter(@"MMM d");
        monthFmt = CalendarFormatter(@"MMM yyyy");
    });
    // NSDateFormatter is thread-safe for formatting on modern Foundation;
    // the formatters above are never mutated after creation.
    return [(withinYear ? dayFmt : monthFmt) stringFromDate:date];
}

static NSString *Plural(long n, NSString *unit) {
    return [NSString stringWithFormat:@"%ld %@%@ ago", n, unit, n == 1 ? @"" : @"s"];
}

NSString *ESRelativeDateDescription(NSDate *date, NSDate *now) {
    NSTimeInterval age = [now timeIntervalSinceDate:date];
    if (age < 0) {
        // Ahead of the clock: a count would be negative, so show the date.
        return CalendarDescription(date, -age < 365.0 * 86400.0);
    }
    if (age < 60.0)            return @"just now";
    if (age < 3600.0)          return [NSString stringWithFormat:@"%ld min ago", lround(floor(age / 60.0))];
    if (age < 48.0 * 3600.0)   return Plural(lround(floor(age / 3600.0)), @"hour");
    if (age < 30.0 * 86400.0)  return Plural(lround(floor(age / 86400.0)), @"day");
    return CalendarDescription(date, age < 365.0 * 86400.0);
}

NSString *ESRelativeDateStamp(NSString *axisWord,
                              NSDate * _Nullable axisDate,
                              NSDate * _Nullable created,
                              NSDate * _Nullable modified,
                              NSDate *now) {
    BOOL edited = created && modified &&
                  [modified timeIntervalSinceDate:created] > kESRelativeDateEditThreshold;

    // "updated" on an entry that was never edited is the store's own write
    // time wearing a revision's clothes. Say what happened instead.
    if ([axisWord isEqualToString:@"updated"] && !edited && created) {
        return [NSString stringWithFormat:@"created %@", ESRelativeDateDescription(created, now)];
    }

    if (!axisDate) return @"";
    NSString *axisAge = ESRelativeDateDescription(axisDate, now);
    NSMutableString *stamp = [NSMutableString stringWithFormat:@"%@ %@", axisWord, axisAge];

    // Sorted by creation and revised since: the revision is news — unless
    // the ladder puts both in the same bucket ("4 days ago, updated 4 days
    // ago"), in which case it says nothing and is dropped.
    if ([axisWord isEqualToString:@"created"] && edited) {
        NSString *editAge = ESRelativeDateDescription(modified, now);
        if (![editAge isEqualToString:axisAge]) {
            [stamp appendFormat:@", updated %@", editAge];
        }
    }
    return stamp;
}

NS_ASSUME_NONNULL_END
