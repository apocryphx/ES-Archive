//
//  ESPipelineFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESPipelineFilter.h"

@implementation ESPipelineStage {
    NSString *_name;
    NSArray<NSString *> *_positional;
    NSDictionary<NSString *, id> *_flags;
}

- (instancetype)initWithName:(NSString *)name
                   positional:(NSArray<NSString *> *)positional
                        flags:(NSDictionary<NSString *, id> *)flags {
    self = [super init];
    if (self) {
        _name = [name copy];
        _positional = [positional ?: @[] copy];
        _flags = [flags ?: @{} copy];
    }
    return self;
}

+ (nullable instancetype)stageFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSString *name = dict[@"name"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) return nil;

    NSArray *pos = dict[@"positional"];
    if (pos && ![pos isKindOfClass:NSArray.class]) return nil;

    NSDictionary *flags = dict[@"flags"];
    if (flags && ![flags isKindOfClass:NSDictionary.class]) return nil;

    return [[self alloc] initWithName:name
                            positional:pos ?: @[]
                                 flags:flags ?: @{}];
}

- (NSString *)name                              { return _name; }
- (NSArray<NSString *> *)positional             { return _positional; }
- (NSDictionary<NSString *, id> *)flags         { return _flags; }

@end
