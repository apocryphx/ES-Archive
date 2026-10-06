//
//  ESDateArgument.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Date arguments on the tool surface, resolved engine-side.
//
//  Every tool that takes a date (archive_store and archive_update's
//  dateCreated, archive_tags' expiresAt and newExpiresAt, archive_timeline's
//  from and to) accepts either an absolute ISO-8601 datetime or a relative
//  offset such as "+30 days", "-2h" or "-1 week". The offset is resolved
//  against the engine's clock at the moment the call runs.
//
//  This used to be a pre-dispatch rewrite in the stdio host (ESBridgeCLI),
//  which meant the promise held over stdio and failed over HTTP. Phase 2 of
//  design-decisions/pipeline-unification.md moved it here so both apps keep
//  it. Foundation only, so it can be unit-tested with a unity include.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parse a date argument. Accepts an absolute ISO-8601 datetime, or a
/// relative offset of the form "+N <unit>" / "-N <unit>" / compact "+1d",
/// "-2h". Units: s, m, h, d, w, mo, y and their longer spellings (sec,
/// second(s), min, minute(s), hr, hour(s), day(s), wk, week(s), month(s),
/// year(s)). Months count as 30 days and years as 365. Returns nil for
/// anything else, including an empty or whitespace-only string.
NSDate * _Nullable ESDateFromArgument(NSString * _Nullable input);

/// The one-line format hint every date-rejecting tool result carries, so
/// the wording stays identical across tools.
NSString *ESDateArgumentHint(void);

NS_ASSUME_NONNULL_END
