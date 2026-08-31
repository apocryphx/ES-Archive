//
//  ESPipelineDiagnostic.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESPipelineDiagnostic.h"

static const NSUInteger kDiagPadWidth = 40;

static NSString *DiagPad(NSString *s) {
    if (s.length >= kDiagPadWidth) return [s stringByAppendingString:@" "];
    NSMutableString *padded = [s mutableCopy];
    while (padded.length < kDiagPadWidth) [padded appendString:@" "];
    return padded;
}

NSString *ESPipelineStageSpelling(NSString *name,
                                   NSArray<NSString *> *positional,
                                   NSDictionary<NSString *, id> *flags) {
    NSMutableString *s = [NSMutableString stringWithString:name];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];

    for (NSString *p in positional) {
        if ([p rangeOfCharacterFromSet:ws].location != NSNotFound) {
            [s appendFormat:@" \"%@\"", p];
        } else {
            [s appendFormat:@" %@", p];
        }
    }

    [flags enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if ([v isKindOfClass:NSNumber.class] && [v boolValue]) {
            [s appendFormat:@" --%@", k];
            return;
        }
        NSString *vs = [NSString stringWithFormat:@"%@", v];
        if ([vs rangeOfCharacterFromSet:ws].location != NSNotFound) {
            [s appendFormat:@" --%@ \"%@\"", k, vs];
        } else {
            [s appendFormat:@" --%@ %@", k, vs];
        }
    }];
    return s;
}

NSString *ESPipelineDiagLine(NSString *spelling,
                              BOOL isFirst,
                              NSArray<NSManagedObjectID *> * _Nullable prior,
                              NSArray<NSManagedObjectID *> *result,
                              ESPipelineFilterKind kind) {
    NSString *prefixed = isFirst ? spelling : [@"| " stringByAppendingString:spelling];
    NSString *padded = DiagPad(prefixed);

    NSString *annotation = @"";
    NSUInteger rn = result.count;
    NSUInteger pn = prior.count;

    switch (kind) {
        case ESPipelineFilterKindFilter:
        case ESPipelineFilterKindLfind:
            if (rn == 0) {
                annotation = @"  (empty — try a different filter or re-order)";
            } else if (prior && rn < pn) {
                double pct = (double)rn / (double)pn * 100.0;
                if (pct < 10.0)        annotation = [NSString stringWithFormat:@"  (highly selective: %.0f%%)", pct];
                else if (pct > 90.0)   annotation = [NSString stringWithFormat:@"  (barely narrowed: %.0f%%)", pct];
                else                   annotation = [NSString stringWithFormat:@"  (selectivity: %.0f%%)", pct];
            }
            break;

        case ESPipelineFilterKindRanker:
            // No annotation in the rn==pn case: the default behavior is
            // re-rank without filtering, and "(all passed threshold)" or
            // "(re-rank only)" on every untouched call is noise. The trace
            // already shows [t=0] (when implicit) or --threshold N (when
            // explicit), so the operating mode is visible without prose.
            if (rn == 0) {
                annotation = @"  (empty — try a different filter or re-order)";
            } else if (prior && rn < pn) {
                double pct = (double)rn / (double)pn * 100.0;
                if (pct < 10.0)        annotation = [NSString stringWithFormat:@"  (highly selective: %.0f%%)", pct];
                else if (pct > 90.0)   annotation = [NSString stringWithFormat:@"  (barely narrowed: %.0f%%)", pct];
                else                   annotation = [NSString stringWithFormat:@"  (selectivity: %.0f%%)", pct];
            }
            break;

        case ESPipelineFilterKindReorder:
        case ESPipelineFilterKindSlice:
        case ESPipelineFilterKindCounter:
        case ESPipelineFilterKindReader:
        case ESPipelineFilterKindUnknown:
            // No annotation — the count itself is the information.
            break;
    }

    return [NSString stringWithFormat:@"%@→ %lu hits%@",
            padded, (unsigned long)rn, annotation];
}
