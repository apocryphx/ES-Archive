//
//  ESRequestScope.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Per-request identity. The channel declares identity: the port a request
//  arrives on maps (via ESServerConfig.portAuthorMap) to a canonical persona
//  author, and that author becomes BOTH the default write stamp and the read
//  scope for every memory tool invoked on that connection. One immutable scope
//  is constructed per request, in the listener's handler closure, and threaded
//  down through dispatch to the tools.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ESRequestScope : NSObject

/// The canonical persona author for this request. Never nil — resolved at
/// construction to: provided author › +[CDMemory defaultAuthor] › @"AI".
@property (nonatomic, readonly, copy) NSString *author;

/// Construct a scope for the given (possibly nil/empty) author. nil/empty falls
/// back through +[CDMemory defaultAuthor] to @"AI", so `author` is always set.
+ (instancetype)scopeWithAuthor:(nullable NSString *)author;

@end

NS_ASSUME_NONNULL_END
