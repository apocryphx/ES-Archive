//
//  CDReference+CoreDataClass.h
//  ES Archive
//
//  Created by Kolja Wawrowsky on 6/27/26.
//
//  A CDReference is a typed, durable pointer to an external resource — a
//  document, a paper, a Drive file, a local file. It holds NO payload: the
//  content lives elsewhere and is resolved on demand. This replaces the old
//  CDAttachment (which stored the bytes inline). See the migration notes:
//  memory holds the gist; the document stays a living file.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

@interface CDReference : NSManagedObject <NSSecureCoding>

/// Create a reference on a memory.
///
/// @param type        Resolver scheme — drive | doi | url | path | bookmark | …
///                    The agent uses this to pick the right resolver.
/// @param handle      The durable token to resolve (Drive fileId, DOI, URL,
///                    absolute path). For a security-scoped `bookmark`, leave
///                    handle nil and set the `bookmark` NSData property instead.
/// @param title       Human/gist label. A cache — a resolver may refresh it.
/// @param url         Optional human-clickable canonical URL.
/// @param contentType Optional MIME of the *target* (e.g. application/pdf).
/// @param note        Optional one-line annotation ("the relevant bit is §3").
+ (instancetype)createOnMemory:(CDMemory *)memory
                          type:(NSString *)type
                        handle:(nullable NSString *)handle
                         title:(nullable NSString *)title
                           url:(nullable NSString *)url
                   contentType:(nullable NSString *)contentType
                          note:(nullable NSString *)note
                        author:(nullable NSString *)author
                       context:(NSManagedObjectContext *)context;

@end

NS_ASSUME_NONNULL_END

#import "CDReference+CoreDataProperties.h"
