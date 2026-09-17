//
//  ESLog.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESLog.h"

BOOL ESTraceEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *v = getenv("ES_ARCHIVE_TRACE");
        enabled = (v && v[0] && strcmp(v, "0") != 0);
    });
    return enabled;
}

double ESTraceClock(void) {
    static double t0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t0 = CFAbsoluteTimeGetCurrent(); });
    return CFAbsoluteTimeGetCurrent() - t0;
}
