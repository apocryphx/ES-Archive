//
//  ESMemoryTagsTool.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  MCP tool: archive_tags
//  "Tag catalog management: list, create, delete, rename, update, merge."
//

#import "ESMemoryTagsTool.h"
#import "CDTag.h"
#import "CDTag+CoreDataProperties.h"
#import "CDMemory.h"
#import "ESCoreDataStack.h"
#import "ESMemoryToolBase.h"

@implementation ESMemoryTagsTool

+ (NSDictionary *)requestJSON {
    return @{
        @"name": @"archive_tags",
        @"description": @"Tag catalog management. Modes: list (filter/paginate the catalog); create (new tag with kind + optional expiresAt — the deliberate provisioning path: it sets kind and expiry up front, unlike connect-or-create on archive_store/archive_tag, which mints unknown names with kind 'thing'. Names are unique, matched case- and diacritic-insensitively across all kinds, so a duplicate name returns status \"already_exists\" and creates nothing — no force or overwrite. Uniqueness is enforced at creation only; multi-device CloudKit sync can rarely leave same-name duplicates, which you resolve with merge); delete (hard-delete tag, detaches from entries); rename (change tag name); update (change kind and/or expiresAt — pass newExpiresAt=null to clear expiry); merge (move all entries from source tag into target and delete source).",
        @"annotations": @{
            @"readOnlyHint": @NO,
            @"destructiveHint": @YES,
            @"idempotentHint": @NO
        },
        @"inputSchema": @{
            @"type": @"object",
            @"properties": @{
                @"mode": @{@"type": @"string", @"description": @"list, create, delete, rename, update, merge", @"enum": @[@"list", @"create", @"delete", @"rename", @"update", @"merge"]},
                @"name": @{@"type": @"string", @"description": @"In list mode: case-insensitive substring filter (e.g. \"Hu\" matches Humboldt, Hundertwasser). In create/delete/rename/update: exact tag name to operate on, matched case- and diacritic-insensitively. In create mode a name already in use returns \"already_exists\" — tag names are unique and there is no overwrite."},
                @"kind": @{@"type": @"string", @"description": @"In list mode: filter by kind. In create mode: descriptive kind (person, place, project, principle, subset, session, research). 'thing' is the uncategorized default that connect-or-create (archive_store/archive_tag) assigns to tags it mints."},
                @"expiresAt": @{@"type": @"string", @"description": @"Create mode: ISO-8601 absolute datetime, or omit for permanent. Bridge resolves relative offsets like \"+30 days\"."},
                @"limit": @{@"type": @"integer", @"description": @"Maximum tags to return (list mode). Default 50."},
                @"offset": @{@"type": @"integer", @"description": @"Skip this many tags before applying limit (list mode). Default 0."},
                @"newName": @{@"type": @"string", @"description": @"New name (rename)."},
                @"newKind": @{@"type": @"string", @"description": @"New kind (update)."},
                @"newExpiresAt": @{@"description": @"Update mode: new ISO-8601 expiration, or null/empty to clear.", @"oneOf": @[@{@"type": @"string"}, @{@"type": @"null"}]},
                @"source": @{@"type": @"string", @"description": @"Merge from tag name."},
                @"target": @{@"type": @"string", @"description": @"Merge into tag name."},
                @"includeExpired": @{@"description": @"List mode: include tags whose dateExpired has passed. Default false.", @"oneOf": @[@{@"type": @"boolean"}, @{@"type": @"string"}]}
            },
            @"required": @[@"mode"]
        }
    };
}

+ (NSDictionary *)executeWithArguments:(NSDictionary *)arguments
                       persistentStore:(NSPersistentCloudKitContainer *)store
                                 scope:(ESRequestScope *)scope
                                 error:(NSError **)error {

    NSString *mode = arguments[@"mode"];
    NSManagedObjectContext *ctx = store.viewContext;

    if ([mode isEqualToString:@"list"]) {
        NSUInteger limit = arguments[@"limit"] ? [arguments[@"limit"] unsignedIntegerValue] : 50;
        NSUInteger offset = arguments[@"offset"] ? [arguments[@"offset"] unsignedIntegerValue] : 0;
        BOOL includeExpired = [ESMemoryToolBase boolFromArgs:arguments key:@"includeExpired" default:NO];
        return [self listWithKind:arguments[@"kind"]
                             name:arguments[@"name"]
                            limit:limit
                           offset:offset
                   includeExpired:includeExpired
                          context:ctx];
    } else if ([mode isEqualToString:@"create"]) {
        return [self createTagWithName:[ESMemoryToolBase stringFromArgs:arguments key:@"name"]
                                  kind:[ESMemoryToolBase stringFromArgs:arguments key:@"kind"]
                          expiresAtRaw:arguments[@"expiresAt"]
                               context:ctx];
    } else if ([mode isEqualToString:@"delete"]) {
        return [self deleteTagWithName:[ESMemoryToolBase stringFromArgs:arguments key:@"name"]
                               context:ctx];
    } else if ([mode isEqualToString:@"rename"]) {
        return [self renameTag:arguments[@"name"] to:arguments[@"newName"] context:ctx];
    } else if ([mode isEqualToString:@"update"]) {
        return [self updateTag:[ESMemoryToolBase stringFromArgs:arguments key:@"name"]
                       newKind:[ESMemoryToolBase stringFromArgs:arguments key:@"newKind"]
               newExpiresAtRaw:arguments[@"newExpiresAt"]
              hasExpiresAtKey:(arguments[@"newExpiresAt"] != nil)
                       context:ctx];
    } else if ([mode isEqualToString:@"merge"]) {
        return [self mergeTag:arguments[@"source"] into:arguments[@"target"] context:ctx];
    }

    return @{@"status": @"unknown_mode"};
}

+ (NSDictionary *)listWithKind:(NSString *)kind
                          name:(NSString *)name
                         limit:(NSUInteger)limit
                        offset:(NSUInteger)offset
                includeExpired:(BOOL)includeExpired
                       context:(NSManagedObjectContext *)ctx {
    NSMutableArray *predicates = [NSMutableArray array];
    if (kind.length > 0) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"kind ==[cd] %@", kind]];
    }
    if (name.length > 0) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", name]];
    }
    if (!includeExpired) {
        // dateExpired == nil  OR  dateExpired > now
        [predicates addObject:[NSPredicate predicateWithFormat:
                               @"dateExpired == nil OR dateExpired > %@", [NSDate now]]];
    }
    NSPredicate *predicate = predicates.count == 1 ? predicates.firstObject
                           : predicates.count  > 1 ? [NSCompoundPredicate andPredicateWithSubpredicates:predicates]
                           : nil;
    NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES];

    NSFetchRequest *countFetch = [CDTag fetchRequest];
    countFetch.predicate = predicate;
    NSUInteger total = [ctx countForFetchRequest:countFetch error:nil];

    NSFetchRequest *fetch = [CDTag fetchRequest];
    fetch.predicate = predicate;
    fetch.sortDescriptors = @[sort];
    fetch.fetchOffset = offset;
    if (limit > 0) fetch.fetchLimit = limit;

    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    NSArray<CDTag *> *tags = [ctx executeFetchRequest:fetch error:nil];
    NSMutableArray *results = [NSMutableArray array];
    for (CDTag *t in tags) {
        NSUInteger memoryCount = 0;
        for (CDMemory *m in t.memories) {
            if (![m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
                memoryCount++;
            }
        }
        NSMutableDictionary *entry = [@{
            @"name": t.name ?: @"",
            @"kind": t.kind ?: @"thing",
            @"memoryCount": @(memoryCount)
        } mutableCopy];
        if (t.dateCreated) entry[@"dateCreated"] = [df stringFromDate:t.dateCreated];
        if (t.dateExpired) {
            entry[@"dateExpired"] = [df stringFromDate:t.dateExpired];
            entry[@"expired"] = @([t.dateExpired compare:[NSDate now]] == NSOrderedAscending);
        }
        [results addObject:entry];
    }
    NSUInteger returned = results.count;
    return @{
        @"total": @(total),
        @"count": @(returned),
        @"offset": @(offset),
        @"truncated": @(offset + returned < total),
        @"tags": results
    };
}

+ (NSDictionary *)createTagWithName:(NSString *)name
                                kind:(NSString *)kind
                        expiresAtRaw:(id)expiresAtRaw
                             context:(NSManagedObjectContext *)ctx {
    if (!name) return @{@"status": @"missing_name"};
    if (!kind) return @{@"status": @"missing_kind"};

    if ([CDTag findByName:name context:ctx]) {
        return @{@"status": @"already_exists", @"name": name};
    }

    NSDate *expiresAt = nil;
    if ([expiresAtRaw isKindOfClass:NSString.class] && [(NSString *)expiresAtRaw length] > 0) {
        NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
        expiresAt = [df dateFromString:(NSString *)expiresAtRaw];
        if (!expiresAt) {
            return @{
                @"status": @"invalid_expiresAt",
                @"hint": @"Provide ISO-8601 (e.g. 2026-06-01T12:00:00Z). Relative offsets are resolved by the bridge."
            };
        }
    }

    CDTag *tag = [NSEntityDescription insertNewObjectForEntityForName:@"CDTag"
                                               inManagedObjectContext:ctx];
    tag.name = name;
    tag.kind = kind;
    tag.dateCreated = [NSDate now];
    tag.dateExpired = expiresAt;

    [[ESCoreDataStack shared] saveContext];

    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    NSMutableDictionary *result = [@{
        @"status": @"created",
        @"name": name,
        @"kind": kind,
        @"dateCreated": [df stringFromDate:tag.dateCreated]
    } mutableCopy];
    if (tag.dateExpired) {
        result[@"dateExpired"] = [df stringFromDate:tag.dateExpired];
    }
    return result;
}

+ (NSDictionary *)deleteTagWithName:(NSString *)name
                             context:(NSManagedObjectContext *)ctx {
    if (!name) return @{@"status": @"missing_name"};

    CDTag *tag = [CDTag findByName:name context:ctx];
    if (!tag) return @{@"status": @"not_found", @"name": name};

    NSUInteger detached = 0;
    for (CDMemory *m in tag.memories) {
        if (![m isKindOfClass:NSClassFromString(@"CDMemoryRevision")]) {
            detached++;
        }
    }

    [ctx deleteObject:tag];
    [[ESCoreDataStack shared] saveContext];

    return @{
        @"status": @"deleted",
        @"name": name,
        @"memoriesDetached": @(detached)
    };
}

+ (NSDictionary *)renameTag:(NSString *)name to:(NSString *)newName context:(NSManagedObjectContext *)ctx {
    if (!name.length || !newName.length) return @{@"status": @"missing_params"};
    CDTag *tag = [CDTag findByName:name context:ctx];
    if (!tag) return @{@"status": @"not_found"};

    // Collision: the target name is already taken. If by a *different* tag, fold
    // this one into it (auto-merge) rather than mint a duplicate name that
    // findByName would then resolve ambiguously — reusing the one merge path. If
    // the match is this same tag (a case-only change like "illucida" → "Illucida",
    // since findByName is case-insensitive), fall through and just fix the casing.
    CDTag *existing = [CDTag findByName:newName context:ctx];
    if (existing && existing != tag) {
        return [self mergeTag:name into:newName context:ctx];
    }

    tag.name = newName;
    [[ESCoreDataStack shared] saveContext];
    return @{@"status": @"renamed", @"oldName": name, @"newName": newName};
}

+ (NSDictionary *)updateTag:(NSString *)name
                    newKind:(NSString *)newKind
            newExpiresAtRaw:(id)newExpiresAtRaw
           hasExpiresAtKey:(BOOL)hasExpiresAtKey
                    context:(NSManagedObjectContext *)ctx {
    if (!name) return @{@"status": @"missing_name"};
    if (!newKind && !hasExpiresAtKey) {
        return @{@"status": @"missing_params", @"hint": @"Provide newKind and/or newExpiresAt."};
    }

    CDTag *tag = [CDTag findByName:name context:ctx];
    if (!tag) return @{@"status": @"not_found", @"name": name};

    // Resolve newExpiresAt only if the key was present.
    NSDate *parsedExpiresAt = nil;
    BOOL clearingExpiry = NO;
    if (hasExpiresAtKey) {
        if (newExpiresAtRaw == nil || [newExpiresAtRaw isKindOfClass:NSNull.class]) {
            clearingExpiry = YES;
        } else if ([newExpiresAtRaw isKindOfClass:NSString.class]) {
            NSString *str = (NSString *)newExpiresAtRaw;
            if (str.length == 0) {
                clearingExpiry = YES;
            } else {
                NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
                parsedExpiresAt = [df dateFromString:str];
                if (!parsedExpiresAt) {
                    return @{
                        @"status": @"invalid_newExpiresAt",
                        @"hint": @"Provide ISO-8601 (e.g. 2026-06-01T12:00:00Z) or null."
                    };
                }
            }
        } else {
            return @{@"status": @"invalid_newExpiresAt"};
        }
    }

    if (newKind) tag.kind = newKind;
    if (hasExpiresAtKey) tag.dateExpired = clearingExpiry ? nil : parsedExpiresAt;

    [[ESCoreDataStack shared] saveContext];

    NSISO8601DateFormatter *df = [[NSISO8601DateFormatter alloc] init];
    NSMutableDictionary *result = [@{
        @"status": @"updated",
        @"name": name
    } mutableCopy];
    if (tag.kind) result[@"kind"] = tag.kind;
    if (tag.dateExpired) {
        result[@"dateExpired"] = [df stringFromDate:tag.dateExpired];
    } else if (hasExpiresAtKey && clearingExpiry) {
        result[@"dateExpired"] = [NSNull null];
    }
    return result;
}

+ (NSDictionary *)mergeTag:(NSString *)sourceName into:(NSString *)targetName context:(NSManagedObjectContext *)ctx {
    if (!sourceName.length || !targetName.length) return @{@"status": @"missing_params"};
    CDTag *source = [CDTag findByName:sourceName context:ctx];
    CDTag *target = [CDTag findByName:targetName context:ctx];
    if (!source) return @{@"status": @"source_not_found"};
    if (!target) return @{@"status": @"target_not_found"};

    // Move all memories from source to target
    for (CDMemory *m in source.memories.allObjects) {
        [m removeTagsObject:source];
        [m addTagsObject:target];
    }

    // Delete source tag
    [ctx deleteObject:source];
    [[ESCoreDataStack shared] saveContext];

    return @{@"status": @"merged", @"source": sourceName, @"target": targetName};
}

@end
