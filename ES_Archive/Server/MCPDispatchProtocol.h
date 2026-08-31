//
//  MCPDispatch.h
//  ES Archive Server
//
//  Created by Kolja Wawrowsky on 3/4/26.
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>

@class ESRequestScope;

NS_ASSUME_NONNULL_BEGIN

@protocol MCPDispatching <NSObject>
@required
+ (NSArray <NSString*>*) methodNames ;
/// Handle a JSON-RPC method. `scope` carries the per-request persona identity
/// derived from the listening port (see ESRequestScope) and is threaded down to
/// the memory tools so reads/writes scope to the connecting persona's author.
/// Dispatchers that don't touch memory simply ignore it.
- (NSDictionary *)handleMethod:(NSString *)method params:(NSDictionary *)params scope:(ESRequestScope *)scope error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
