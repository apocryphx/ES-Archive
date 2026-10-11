//
//  ESRelativeDate.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Human-scale age for a recalled entry.
//
//  Recall surfaces (archive_timeline, the pipeline's arc rows) used to carry
//  a full ISO-8601 timestamp per row. For a reader the stamp is arithmetic
//  homework: it has to be subtracted from a "now" the reader only roughly
//  knows. Rendering the age engine-side, where the clock is exact, hands
//  over the answer instead of the question — and in a handful of
//  characters rather than thirty.
//
//  The granularity decays with age. Hours are useful at 27 hours; "167
//  days ago" is not, and a sorted list already carries the ordering, so
//  older stamps fall back to a short calendar date, which is easier to
//  reason about at that distance than a count.
//
//  The age is correct only at response time. It is rendering, not data:
//  nothing that copies a recalled row into a new entry should keep it.
//  Callers that need the exact instant ask for it (timeline's `exact`,
//  or `cat`, which always emits ISO dates). Foundation only, so it can be
//  unit-tested with a unity include like ESDateArgument.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The age of `date` relative to `now`, on a decaying ladder:
///   under a minute      → "just now"
///   under an hour       → "N min ago"
///   under two days      → "N hour(s) ago"
///   under thirty days   → "N day(s) ago"
///   under a year        → "Mar 12"           (calendar date, no year)
///   older               → "Mar 2026"         (month and year)
/// A `date` in the future (clock skew, a backdated entry whose dateCreated
/// was set ahead) renders as its calendar date rather than a negative age.
/// Calendar forms use the Gregorian calendar, UTC and en_US_POSIX, so the
/// output is stable across the engine's locale.
NSString *ESRelativeDateDescription(NSDate *date, NSDate *now);

/// One stamp for a recalled row. `axisWord` is the verb for the sorted
/// axis ("created", "updated", "read"); `axisDate` the date on that axis.
/// Pass `created` and `modified` too, and the function decides whether a
/// second stamp carries news: an entry sorted by creation that was edited
/// well after it was created gets ", updated …" appended; an entry sorted
/// by modification that was never edited reads "created …" instead of a
/// misleading "updated …". Returns e.g. "created 27 hours ago" or
/// "created 3 days ago, updated 2 hours ago". Any nil date is skipped.
NSString *ESRelativeDateStamp(NSString *axisWord,
                              NSDate * _Nullable axisDate,
                              NSDate * _Nullable created,
                              NSDate * _Nullable modified,
                              NSDate *now);

NS_ASSUME_NONNULL_END
