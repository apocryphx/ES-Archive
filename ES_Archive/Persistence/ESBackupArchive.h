//
//  ESBackupArchive.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Top-level NSSecureCoding wrapper written to / read from .esmemory backup
//  files by ESBackupManager. Holds a schema version, a capture date, the app
//  version, and the flat arrays of CDMemory and CDLink that make up the
//  snapshot. Cascade-owned children (attachments, marginalia, revisions) and
//  tag {name, kind} dicts are carried inside each CDMemory; CDVector is
//  intentionally excluded and regenerated after restore.
//

#import <Foundation/Foundation.h>

@class CDMemory, CDLink;

NS_ASSUME_NONNULL_BEGIN

/// Current archive schema version. Bump when the encoded shape changes in a
/// way that older app builds can't safely read.
FOUNDATION_EXTERN const int32_t ESBackupArchiveCurrentSchemaVersion;

@interface ESBackupArchive : NSObject <NSSecureCoding>

@property (nonatomic, assign) int32_t schemaVersion;
@property (nonatomic, copy, nullable)   NSDate   *dateCreated;
@property (nonatomic, copy, nullable)   NSString *appVersion;
@property (nonatomic, copy) NSArray<CDMemory *> *memories;
@property (nonatomic, copy) NSArray<CDLink   *> *links;

@end

NS_ASSUME_NONNULL_END
