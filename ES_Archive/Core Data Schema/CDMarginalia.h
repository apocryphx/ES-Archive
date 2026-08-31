//
//  CDMarginalia.h
//  
//
//  Created by Kolja Wawrowsky on 3/4/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

@interface CDMarginalia : NSManagedObject <NSSecureCoding>

/// Create a marginal note on a memory.
+ (instancetype)createOnMemory:(CDMemory *)memory
                          body:(NSString *)body
                        author:(NSString *)author
                       context:(NSManagedObjectContext *)context;

@end

NS_ASSUME_NONNULL_END

#import "CDMarginalia+CoreDataProperties.h"
