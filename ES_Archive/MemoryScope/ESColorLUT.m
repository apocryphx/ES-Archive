//
//  ESColorLUT.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESColorLUT.h"

#define kLUTSize 256

@implementation ESColorLUT {
    NSColor *_table[kLUTSize];
    CGColorRef _cgTable[kLUTSize];
}

- (instancetype)initWithName:(NSString *)name
               controlPoints:(NSArray<NSDictionary *> *)points {
    self = [super init];
    if (!self) return nil;
    _name = [name copy];
    [self buildTableFromControlPoints:points];
    return self;
}

- (void)dealloc {
    for (NSUInteger i = 0; i < kLUTSize; i++) {
        if (_cgTable[i]) CGColorRelease(_cgTable[i]);
    }
}

#pragma mark - Table Construction

- (void)buildTableFromControlPoints:(NSArray<NSDictionary *> *)points {
    // points: @[@{@"t": @0.0, @"r": @0.0, @"g": @0.0, @"b": @1.0}, ...]
    for (NSUInteger i = 0; i < kLUTSize; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)(kLUTSize - 1);

        // Find surrounding control points
        NSDictionary *lo = points.firstObject;
        NSDictionary *hi = points.lastObject;
        for (NSUInteger j = 0; j < points.count - 1; j++) {
            CGFloat t0 = [points[j][@"t"] doubleValue];
            CGFloat t1 = [points[j + 1][@"t"] doubleValue];
            if (t >= t0 && t <= t1) {
                lo = points[j];
                hi = points[j + 1];
                break;
            }
        }

        CGFloat tLo = [lo[@"t"] doubleValue];
        CGFloat tHi = [hi[@"t"] doubleValue];
        CGFloat frac = (tHi > tLo) ? (t - tLo) / (tHi - tLo) : 0.0;

        CGFloat r = [lo[@"r"] doubleValue] + frac * ([hi[@"r"] doubleValue] - [lo[@"r"] doubleValue]);
        CGFloat g = [lo[@"g"] doubleValue] + frac * ([hi[@"g"] doubleValue] - [lo[@"g"] doubleValue]);
        CGFloat b = [lo[@"b"] doubleValue] + frac * ([hi[@"b"] doubleValue] - [lo[@"b"] doubleValue]);

        _table[i] = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
        _cgTable[i] = CGColorRetain(_table[i].CGColor);
    }
}

#pragma mark - Lookup

- (NSColor *)colorForValue:(CGFloat)value {
    NSUInteger idx = (NSUInteger)(fmin(fmax(value, 0.0), 1.0) * (kLUTSize - 1));
    return _table[idx];
}

- (CGColorRef)cgColorForValue:(CGFloat)value {
    NSUInteger idx = (NSUInteger)(fmin(fmax(value, 0.0), 1.0) * (kLUTSize - 1));
    return _cgTable[idx];
}

#pragma mark - Factory

+ (ESColorLUT *)hotCold {
    static ESColorLUT *lut;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lut = [[ESColorLUT alloc] initWithName:@"Hot-Cold" controlPoints:@[
            @{@"t": @0.00, @"r": @0.0,  @"g": @0.0,  @"b": @1.0},  // blue
            @{@"t": @0.25, @"r": @0.0,  @"g": @0.8,  @"b": @1.0},  // cyan
            @{@"t": @0.50, @"r": @0.0,  @"g": @1.0,  @"b": @0.0},  // green
            @{@"t": @0.75, @"r": @1.0,  @"g": @1.0,  @"b": @0.0},  // yellow
            @{@"t": @1.00, @"r": @1.0,  @"g": @0.0,  @"b": @0.0},  // red
        ]];
    });
    return lut;
}

@end
