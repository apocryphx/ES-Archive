//
//  CDEmbedder+CoreDataClass.m
//  ES Archive MCP
//
//  Created by Kolja Wawrowsky on 5/6/26.
//
//

#import "CDEmbedder.h"

@implementation CDEmbedder

#pragma mark - Lookup

+ (nullable CDEmbedder *)findOrCreateWithIdentifier:(NSString *)identifier
                                          dimension:(NSUInteger)dimension
                                          inContext:(NSManagedObjectContext *)context {
    if (identifier.length == 0 || !context) return nil;

    NSFetchRequest *req = [self fetchRequest];
    req.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", identifier];
    req.fetchLimit = 1;

    NSError *err = nil;
    NSArray<CDEmbedder *> *results = [context executeFetchRequest:req error:&err];
    if (err) {
        NSLog(@"CDEmbedder findOrCreate fetch failed for %@: %@", identifier, err);
        return nil;
    }

    if (results.count > 0) {
        CDEmbedder *existing = results.firstObject;
        if (dimension > 0 && existing.vectorDimension != (int32_t)dimension) {
            NSLog(@"CDEmbedder dimension mismatch for %@: stored=%d, requested=%lu — "
                  @"keeping stored value; vectors may need re-embedding",
                  identifier, existing.vectorDimension, (unsigned long)dimension);
        }
        return existing;
    }

    CDEmbedder *fresh = [NSEntityDescription insertNewObjectForEntityForName:@"CDEmbedder"
                                                       inManagedObjectContext:context];
    fresh.identifier = identifier;
    fresh.vectorDimension = (int32_t)dimension;
    NSDate *now = [NSDate now];
    fresh.dateCreated = now;
    fresh.dateLastUsed = now;
    return fresh;
}

#pragma mark - Lifecycle

- (void)touchDateLastUsed {
    NSDate *now = [NSDate now];
    if (!self.dateLastUsed || [now timeIntervalSinceDate:self.dateLastUsed] > 60.0) {
        self.dateLastUsed = now;
    }
}

- (void)touchDateLastActivated {
    // No throttle — explicit activation events are rare and each one matters.
    self.dateLastActivated = [NSDate now];
}

@end
