//
//  CDMemory.h
//  
//
//  Created by Kolja Wawrowsky on 2/28/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDLink, CDMemoryRevision, CDTag, CDVector, CDMarginalia, CDReference;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const CDMemoryErrorDomain;

typedef NS_ENUM(NSInteger, CDMemoryErrorCode) {
    CDMemoryErrorInvalidContext = 3000,
    CDMemoryErrorMissingBody,
    CDMemoryErrorSaveFailed
};


@interface CDMemory : NSManagedObject <NSSecureCoding>

#pragma mark - Identity

/// The default author stamped on memories, comments, and attachments created
/// through this build when the caller supplies no explicit author. Each app
/// target carries its own identity in its Info.plist under the `ESDefaultAuthor`
/// key ("Claude" for ES Archive MCP, "Isolde" for Isoldes Sheep); this reads it
/// once and caches it, falling back to a neutral "AI" if the key is absent.
+ (NSString *)defaultAuthor;

#pragma mark - Factory

/// Create a new memory. Title is extracted from the first line of body.
+ (nullable CDMemory *)createWithBody:(NSString *)body
                                 type:(nullable NSString *)type
                               locked:(BOOL)locked
                              private:(BOOL)isPrivate
                                 tags:(nullable NSArray<NSDictionary *> *)tagDicts
                              context:(NSManagedObjectContext *)ctx
                                error:(NSError **)error;

#pragma mark - Title Extraction

/// Extract the first line of body as the title. Call before save.
- (void)extractTitleFromBody;

#pragma mark - Access Tracking

/// Increment accessCount, update dateAccessed.
- (void)recordAccess;

#pragma mark - Semantic Handles

/// Lightweight summary: {title, author, type, dateCreated, accessCount}
- (NSDictionary *)semanticSummary;

#pragma mark - Graph Traversal

- (NSArray<CDLink *> *)outgoingLinks;
- (NSArray<CDLink *> *)incomingLinks;
- (NSArray<NSDictionary *> *)connectedMemorySummaries;

#pragma mark - Vector Generation

/// Generate vector embedding from body text. Async — saves in a second transaction.
- (void)generateVector;

#pragma mark - Vector Selection (multi-embedder)

/// The CDVector for this memory produced by the embedder with the given
/// identifier, or nil if no such vector exists. With Phase-1 multi-embedder
/// schema, each memory may have multiple vectors (one per embedder); this
/// is the typed lookup.
- (nullable CDVector *)vectorForEmbedderIdentifier:(NSString *)identifier;

/// The CDVector for this memory produced by the currently active summary
/// embedder. Resolves via ESVectorEngine.summaryEmbedder.identifier, then
/// dispatches to vectorForEmbedderIdentifier:. Returns nil if no summary
/// embedder is registered or if no matching vector exists for this memory.
- (nullable CDVector *)vectorForActiveEmbedder;
@end

NS_ASSUME_NONNULL_END

#import "CDMemory+CoreDataProperties.h"

