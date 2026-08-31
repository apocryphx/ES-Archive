//
//  ESMemoryToolBase.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESMemoryToolBase.h"
#import "CDMemory.h"

@implementation ESMemoryToolBase

#pragma mark - Persona scoping

+ (NSPredicate *)scopePredicateForAuthor:(NSString *)scopeAuthor {
    if (![scopeAuthor isKindOfClass:NSString.class] || scopeAuthor.length == 0) {
        // Fail closed: a missing scope must surface nothing, never everything.
        return [NSPredicate predicateWithValue:NO];
    }
    return [NSPredicate predicateWithFormat:@"author == %@", scopeAuthor];
}

+ (NSPredicate *)identityScopeForAuthor:(NSString *)scopeAuthor {
    NSPredicate *scope = [self scopePredicateForAuthor:scopeAuthor];
    // Keep nil-typed and every non-fiction type; drop only type == "fiction".
    NSPredicate *nonFiction = [NSPredicate predicateWithFormat:@"(type == nil OR type !=[c] %@)", @"fiction"];
    return [NSCompoundPredicate andPredicateWithSubpredicates:@[scope, nonFiction]];
}

+ (NSString *)effectiveAuthorForScope:(NSString *)scopeAuthor
                             explicit:(NSString *)explicitAuthor {
    if ([explicitAuthor isKindOfClass:NSString.class] && explicitAuthor.length > 0) {
        return explicitAuthor;
    }
    if ([scopeAuthor isKindOfClass:NSString.class] && scopeAuthor.length > 0) {
        return scopeAuthor;
    }
    return [CDMemory defaultAuthor]; // already terminates in @"AI"
}

+ (void)postAccessNotification:(ESMemoryAccessType)type
                     objectIDs:(NSArray<NSManagedObjectID *> *)objectIDs
                        scores:(nullable NSArray<NSNumber *> *)scores
                      originID:(nullable NSManagedObjectID *)originID {

    if (objectIDs.count == 0 && !originID) return;

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[ESMemoryAccessTypeKey]      = @(type);
    userInfo[ESMemoryAccessObjectIDsKey] = objectIDs ?: @[];
    if (scores)   userInfo[ESMemoryAccessScoresKey]  = scores;
    if (originID) userInfo[ESMemoryAccessOriginIDKey] = originID;

    NSDictionary *payload = [userInfo copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ESMemoryAccessNotification
                          object:nil
                        userInfo:payload];
    });
}

#pragma mark - Argument Coercion Helpers

+ (NSInteger)integerFromArgs:(NSDictionary *)args
                          key:(NSString *)key
                      default:(NSInteger)def {
    id v = args[key];
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v integerValue];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)v;
        if (s.length == 0) return def;
        // Reject non-numeric strings — integerValue returns 0 silently otherwise.
        NSScanner *sc = [NSScanner scannerWithString:s];
        NSInteger out = 0;
        if ([sc scanInteger:&out] && sc.isAtEnd) return out;
    }
    return def;
}

+ (NSUInteger)unsignedIntegerFromArgs:(NSDictionary *)args
                                   key:(NSString *)key
                               default:(NSUInteger)def {
    id v = args[key];
    if ([v isKindOfClass:NSNumber.class]) {
        NSInteger n = [(NSNumber *)v integerValue];
        return n < 0 ? def : (NSUInteger)n;
    }
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)v;
        if (s.length == 0) return def;
        NSScanner *sc = [NSScanner scannerWithString:s];
        NSInteger out = 0;
        if ([sc scanInteger:&out] && sc.isAtEnd && out >= 0) return (NSUInteger)out;
    }
    return def;
}

+ (BOOL)boolFromArgs:(NSDictionary *)args
                  key:(NSString *)key
              default:(BOOL)def {
    id v = args[key];
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"yes"] || [s isEqualToString:@"1"]) return YES;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"] || [s isEqualToString:@"0"]) return NO;
    }
    return def;
}

+ (nullable NSString *)stringFromArgs:(NSDictionary *)args
                                   key:(NSString *)key {
    id v = args[key];
    if ([v isKindOfClass:NSString.class] && ((NSString *)v).length > 0) return (NSString *)v;
    return nil;
}

+ (nullable NSArray *)arrayFromArgs:(NSDictionary *)args
                                 key:(NSString *)key {
    id v = args[key];
    if ([v isKindOfClass:NSArray.class]) return (NSArray *)v;
    return nil;
}

+ (NSArray<NSDictionary *> *)tagArrayFromArgs:(NSDictionary *)args
                                            key:(NSString *)key {
    id v = args[key];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];

    // A JSON array/object can arrive already serialized to a string — some MCP
    // bridges stringify structured arguments. Recover it BEFORE the comma
    // shorthand, or '[{"name":"x"},{"name":"y"}]' gets split on its inner commas
    // into garbage tag names like '[{"name":"x"' and '"kind":"thing"}'.
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([s hasPrefix:@"["] || [s hasPrefix:@"{"]) {
            id parsed = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:NULL];
            // A JSON-looking string MUST parse as JSON — it must never fall
            // through to the comma splitter, which would shred
            // '[{"name":"x"},{"name":"y"}]' into garbage tag names like
            // '[{"name":"x"'. If it won't parse, treat it as no tags rather
            // than fabricating fragments. (Well-formed JSON strings are the
            // common bridge-stringified case and parse fine.)
            v = parsed ?: @[];
        }
    }
    // A single {name,kind} object is treated as a one-element array.
    if ([v isKindOfClass:NSDictionary.class]) v = @[v];

    if ([v isKindOfClass:NSArray.class]) {
        for (id entry in (NSArray *)v) {
            if ([entry isKindOfClass:NSDictionary.class]) {
                NSDictionary *d = (NSDictionary *)entry;
                NSString *name = d[@"name"];
                if ([name isKindOfClass:NSString.class] && name.length > 0) {
                    [out addObject:d];
                }
            } else if ([entry isKindOfClass:NSString.class] && ((NSString *)entry).length > 0) {
                [out addObject:@{@"name": entry, @"kind": @"thing"}];
            }
        }
    } else if ([v isKindOfClass:NSString.class]) {
        // Comma-separated shorthand: "a,b,c" → 3 thing-tags.
        for (NSString *t in [(NSString *)v componentsSeparatedByString:@","]) {
            NSString *name = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (name.length > 0) [out addObject:@{@"name": name, @"kind": @"thing"}];
        }
    }
    return out;
}

@end
