//
//  ESDedupeMergeCore.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Extracted verbatim from ESMemoryMaintenanceTool's dedupeMemories loop
//  (July 2026) so the automatic deduplicator and the maintenance action
//  share one merge implementation.
//

#import "ESDedupeMergeCore.h"
#import "CDMemory.h"
#import "CDTag.h"
#import "CDLink.h"
#import "CDMarginalia.h"
#import "CDReference.h"
#import "CDMemoryRevision.h"
#import "CDVector.h"

NSDictionary<NSString *, NSNumber *> *ESDedupeMergeSortedGroup(NSArray<CDMemory *> *sorted,
                                                               NSManagedObjectContext *ctx) {
    NSUInteger deleted = 0, tagsMoved = 0, linksMoved = 0,
               commentsMoved = 0, referencesMoved = 0, revisionsMoved = 0;

    CDMemory *survivor = sorted.firstObject;

    BOOL anyLocked = NO;
    for (CDMemory *m in sorted) { if (m.locked) { anyLocked = YES; break; } }
    // A locked duplicate is still a duplicate. `locked` is just a flag:
    // deleting a twin doesn't touch it, and the survivor inherits it, so a
    // sealed record's CloudKit twin collapses without breaking the seal.
    if (anyLocked) survivor.locked = YES;

    for (CDMemory *dup in sorted) {
        if (dup == survivor) continue;
        deleted++;

        // Tags — union onto the survivor.
        for (CDTag *t in dup.tags.allObjects) {
            if (![survivor.tags containsObject:t]) tagsMoved++;
            [dup removeTagsObject:t];
            [survivor addTagsObject:t];
        }

        // Links — re-point, dropping self-loops and edges the survivor
        // already has. CDMemory→links is Cascade, so anything left on the
        // duplicate dies with it.
        for (CDLink *l in dup.sourceLinks.allObjects) {
            BOOL redundant = (l.targetMemory == survivor);
            if (!redundant) {
                NSString *edge = l.edge ?: @"";
                for (CDLink *existing in survivor.sourceLinks) {
                    if (existing.targetMemory == l.targetMemory &&
                        [(existing.edge ?: @"") isEqualToString:edge]) { redundant = YES; break; }
                }
            }
            if (redundant) { [ctx deleteObject:l]; }
            else           { l.sourceMemory = survivor; linksMoved++; }
        }
        for (CDLink *l in dup.targetLinks.allObjects) {
            BOOL redundant = (l.sourceMemory == survivor);
            if (!redundant) {
                NSString *edge = l.edge ?: @"";
                for (CDLink *existing in survivor.targetLinks) {
                    if (existing.sourceMemory == l.sourceMemory &&
                        [(existing.edge ?: @"") isEqualToString:edge]) { redundant = YES; break; }
                }
            }
            if (redundant) { [ctx deleteObject:l]; }
            else           { l.targetMemory = survivor; linksMoved++; }
        }

        // Comments, references, revision history — all follow the survivor.
        for (CDMarginalia *note in dup.marginalia.allObjects)   { note.memory = survivor; commentsMoved++; }
        for (CDReference *ref in dup.references.allObjects)     { ref.memory  = survivor; referencesMoved++; }
        for (CDMemoryRevision *rev in dup.revisions.allObjects) { rev.memory  = survivor; revisionsMoved++; }

        // A duplicate's vector fills the survivor's slot when the survivor
        // lacks one for that embedder; otherwise it dies with the duplicate
        // (Cascade). Twin bodies are identical, so the embeddings are too.
        for (CDVector *v in dup.vectors.allObjects) {
            BOOL survivorHas = NO;
            NSString *vid = v.embedderIdentifier ?: @"";
            for (CDVector *sv in survivor.vectors) {
                if ([(sv.embedderIdentifier ?: @"") isEqualToString:vid]) { survivorHas = YES; break; }
            }
            if (!survivorHas) v.memory = survivor;
        }

        // Reading stats fold together; privacy is the stricter of the two.
        survivor.accessCount = MAX(survivor.accessCount, dup.accessCount);
        if (dup.dateAccessed && (!survivor.dateAccessed ||
            [dup.dateAccessed compare:survivor.dateAccessed] == NSOrderedDescending)) {
            survivor.dateAccessed = dup.dateAccessed;
        }
        if (dup.private) survivor.private = YES;

        [ctx deleteObject:dup];
    }

    return @{
        @"deleted":         @(deleted),
        @"tagsMoved":       @(tagsMoved),
        @"linksMoved":      @(linksMoved),
        @"commentsMoved":   @(commentsMoved),
        @"referencesMoved": @(referencesMoved),
        @"revisionsMoved":  @(revisionsMoved),
        @"lockedGroup":     @(anyLocked ? 1 : 0),
    };
}
