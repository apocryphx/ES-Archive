//
//  CDLink.h
//  
//
//  Created by Kolja Wawrowsky on 2/28/26.
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "ESUUIDStampedObject.h"

@class CDMemory;

NS_ASSUME_NONNULL_BEGIN

@interface CDLink : ESUUIDStampedObject <NSSecureCoding>

@end

NS_ASSUME_NONNULL_END

#import "CDLink+CoreDataProperties.h"
