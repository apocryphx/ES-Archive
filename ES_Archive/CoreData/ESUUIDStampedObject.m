//
//  ESUUIDStampedObject.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESUUIDStampedObject.h"
#import "ESLog.h"

@implementation ESUUIDStampedObject

- (void)awakeFromInsert {
    [super awakeFromInsert];
    if (self.entity.attributesByName[@"uuid"] != nil &&
        [self valueForKey:@"uuid"] == nil) {
        [self setValue:[NSUUID UUID] forKey:@"uuid"];
    }
}

+ (NSUInteger)backfillUUIDsInContext:(NSManagedObjectContext *)ctx {
    NSManagedObjectModel *model = ctx.persistentStoreCoordinator.managedObjectModel;
    NSUInteger stamped = 0;

    for (NSEntityDescription *entity in model.entities) {
        if (entity.superentity != nil) continue;   // subentities ride the root fetch
        if (entity.attributesByName[@"uuid"] == nil) continue;

        NSFetchRequest *req = [NSFetchRequest fetchRequestWithEntityName:entity.name];
        req.predicate = [NSPredicate predicateWithFormat:@"uuid == nil"];

        NSError *err = nil;
        NSArray<NSManagedObject *> *rows = [ctx executeFetchRequest:req error:&err];
        if (err || !rows) {
            ESLogAlways(@"UUID backfill: %@ fetch failed: %@",
                        entity.name, err.localizedDescription);
            continue;
        }
        for (NSManagedObject *obj in rows) {
            [obj setValue:[NSUUID UUID] forKey:@"uuid"];
            stamped++;
        }
        if (rows.count > 0) {
            ESLog(@"UUID backfill: stamped %lu %@ row%s",
                  (unsigned long)rows.count, entity.name, rows.count == 1 ? "" : "s");
        }
    }
    return stamped;
}

@end
