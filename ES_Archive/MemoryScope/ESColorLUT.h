//
//  ESColorLUT.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//


#import <Cocoa/Cocoa.h>

/// 256-entry color lookup table for mapping normalized values [0,1] to colors.
@interface ESColorLUT : NSObject

@property (nonatomic, copy, readonly) NSString *name;

+ (ESColorLUT *)hotCold;    // blue → cyan → green → yellow → red (node heat)

/// Returns the color for a normalized value in [0, 1].
- (NSColor *)colorForValue:(CGFloat)value;

/// Returns the CGColor for a normalized value. Caller does NOT own the result.
- (CGColorRef)cgColorForValue:(CGFloat)value;

@end
