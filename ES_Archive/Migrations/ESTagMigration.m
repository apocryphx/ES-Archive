//
//  ESTagMigration.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESTagMigration.h"
#import "CDTag.h"
#import "ESLog.h"

static NSString * const kESTagPurgeMay2026DoneKey = @"ESTagPurgeMay2026Done";

@implementation ESTagMigration

+ (NSUInteger)runIfNeededWithContext:(NSManagedObjectContext *)ctx {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kESTagPurgeMay2026DoneKey]) return 0;
    if (!ctx) return 0;

    __block NSUInteger purged = 0;
    __block BOOL ok = NO;
    [ctx performBlockAndWait:^{
        NSFetchRequest *fetch = [CDTag fetchRequest];
        NSError *fetchErr = nil;
        NSArray<CDTag *> *all = [ctx executeFetchRequest:fetch error:&fetchErr];
        if (fetchErr) {
            NSLog(@"ESTagMigration: fetch failed: %@", fetchErr);
            return;
        }
        for (CDTag *tag in all) {
            [ctx deleteObject:tag];
            purged++;
        }
        if (ctx.hasChanges) {
            NSError *saveErr = nil;
            if (![ctx save:&saveErr]) {
                NSLog(@"ESTagMigration: save failed: %@", saveErr);
                return;
            }
        }
        ok = YES;
    }];

    if (ok) {
        [defaults setBool:YES forKey:kESTagPurgeMay2026DoneKey];
        ESLog(@"ESTagMigration: purged %lu legacy auto-tags. Tag layer is now empty by design.",
              (unsigned long)purged);
    }
    return purged;
}

@end
