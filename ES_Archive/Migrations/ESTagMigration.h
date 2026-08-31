//
//  ESTagMigration.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  One-time destructive migration that drops every existing CDTag row.
//  Runs on first launch after the May 2026 tag-layer redesign — the legacy
//  tags were all auto-extracted by NLTagger and carry no curatorial value;
//  the new design starts the tag layer empty.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESTagMigration : NSObject

/// Runs the migration if it hasn't run yet on this machine. Idempotent —
/// safe to call on every launch. Returns the number of tags purged on this
/// invocation (0 on subsequent launches).
+ (NSUInteger)runIfNeededWithContext:(NSManagedObjectContext *)ctx;

@end

NS_ASSUME_NONNULL_END
