//
//  ESSummaryEmbedder.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Runtime introspection helpers for the ESSummaryEmbedder protocol.
//  The protocol itself is header-only; this file is the discovery
//  surface and the locale-based resolver.
//

#import "ESSummaryEmbedder.h"
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Class discovery

NSArray<Class> *ESSummaryEmbedderAvailableClasses(void) {
    static dispatch_once_t once;
    static NSArray<Class> *cache = nil;
    dispatch_once(&once, ^{
        Protocol *proto = @protocol(ESSummaryEmbedder);
        unsigned int n = 0;
        Class *all = objc_copyClassList(&n);
        NSMutableArray<Class> *out = [NSMutableArray array];
        for (unsigned int i = 0; i < n; i++) {
            Class c = all[i];
            Class walk = c;
            BOOL conforms = NO;
            while (walk) {
                if (class_conformsToProtocol(walk, proto)) {
                    conforms = YES;
                    break;
                }
                walk = class_getSuperclass(walk);
            }
            if (conforms) [out addObject:c];
        }
        free(all);
        cache = [out copy];
    });
    return cache;
}

#pragma mark - Instantiation

/// Probed factory selectors, in order of preference.
static SEL ESSummaryEmbedderFactorySelectors[3] = { NULL, NULL, NULL };

static void ESSummaryEmbedderInitFactorySelectors(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ESSummaryEmbedderFactorySelectors[0] = NSSelectorFromString(@"defaultEmbedder");
        ESSummaryEmbedderFactorySelectors[1] = NSSelectorFromString(@"sharedEmbedder");
        ESSummaryEmbedderFactorySelectors[2] = NSSelectorFromString(@"new");
    });
}

NSArray<id<ESSummaryEmbedder>> *ESSummaryEmbedderActiveInstances(void) {
    static dispatch_once_t once;
    static NSArray<id<ESSummaryEmbedder>> *cache = nil;
    dispatch_once(&once, ^{
        ESSummaryEmbedderInitFactorySelectors();
        NSArray<Class> *classes = ESSummaryEmbedderAvailableClasses();
        NSMutableArray<id<ESSummaryEmbedder>> *out = [NSMutableArray array];
        for (Class c in classes) {
            id<ESSummaryEmbedder> instance = nil;
            for (size_t i = 0; i < sizeof(ESSummaryEmbedderFactorySelectors)/sizeof(SEL); i++) {
                SEL sel = ESSummaryEmbedderFactorySelectors[i];
                if ([c respondsToSelector:sel]) {
                    IMP imp = [c methodForSelector:sel];
                    id (*fn)(id, SEL) = (void *)imp;
                    instance = fn(c, sel);
                    if (instance) break;
                }
            }
            if (instance) [out addObject:instance];
        }
        cache = [out copy];
    });
    return cache;
}

#pragma mark - Priority + locale resolver

/// Resolve the optional +priority class method via typed objc_msgSend.
/// `[(id)[e class] priority]` is ambiguous to the compiler — `priority`
/// exists on several Foundation types with different return signatures.
/// Returns 0 when unimplemented.
static NSInteger ESSummaryEmbedderClassPriority(id<ESSummaryEmbedder> e) {
    Class cls = object_getClass(e);
    if (![cls respondsToSelector:@selector(priority)]) return 0;
    return ((NSInteger (*)(Class, SEL))objc_msgSend)(cls, @selector(priority));
}

/// Root tag of a BCP 47 string — everything before the first `-`.
/// `@"zh-Hans-CN"` → `@"zh"`. Returns `@""` for nil/empty input.
static NSString *ESRootLanguageTag(NSString *bcp47) {
    if (bcp47.length == 0) return @"";
    NSRange dash = [bcp47 rangeOfString:@"-"];
    return dash.location == NSNotFound ? bcp47 : [bcp47 substringToIndex:dash.location];
}

/// Pick from `instances` the one whose `language` equals `tag`, breaking
/// ties by priority descending. Returns nil when no instance matches.
static id<ESSummaryEmbedder> ESPickByLanguage(NSArray<id<ESSummaryEmbedder>> *instances,
                                              NSString *tag) {
    id<ESSummaryEmbedder> best = nil;
    NSInteger bestPri = NSIntegerMin;
    for (id<ESSummaryEmbedder> e in instances) {
        if (![e.language isEqualToString:tag]) continue;
        NSInteger pri = ESSummaryEmbedderClassPriority(e);
        if (pri > bestPri) {
            best = e;
            bestPri = pri;
        }
    }
    return best;
}

id<ESSummaryEmbedder> ESSummaryEmbedderForCurrentLocale(void) {
    NSArray<id<ESSummaryEmbedder>> *active = ESSummaryEmbedderActiveInstances();
    if (active.count == 0) return nil;

    NSString *preferred = [NSLocale preferredLanguages].firstObject;
    NSString *root = ESRootLanguageTag(preferred);

    id<ESSummaryEmbedder> match = ESPickByLanguage(active, root);
    if (match) return match;

    // No direct match — fall back to the best English instance.
    return ESPickByLanguage(active, @"en");
}
