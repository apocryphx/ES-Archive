//
//  CDTag.m
//
//
//  Created by Kolja Wawrowsky on 2/28/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "CDTag.h"
#import "CDMemory.h"

@implementation CDTag

+ (CDTag *)findByName:(NSString *)name context:(NSManagedObjectContext *)ctx {
    if (!name || name.length == 0 || !ctx) return nil;

    NSFetchRequest *fetch = [CDTag fetchRequest];
    fetch.predicate = [NSPredicate predicateWithFormat:@"name ==[cd] %@", name];
    fetch.fetchLimit = 1;

    NSError *error = nil;
    NSArray *results = [ctx executeFetchRequest:fetch error:&error];
    if (error) {
        NSLog(@"CDTag findByName error: %@", error);
        return nil;
    }
    return results.firstObject;
}

+ (CDTag *)findOrCreateByName:(NSString *)name kind:(NSString *)kind context:(NSManagedObjectContext *)ctx {
    if (!name || name.length == 0 || !ctx) return nil;
    CDTag *existing = [self findByName:name context:ctx];
    if (existing) return existing;
    CDTag *tag = [NSEntityDescription insertNewObjectForEntityForName:@"CDTag"
                                              inManagedObjectContext:ctx];
    tag.name = name;
    tag.kind = (kind.length > 0) ? kind : @"thing";
    tag.dateCreated = [NSDate now];
    return tag;
}

@end
