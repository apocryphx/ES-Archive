//
//  ESManFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  man — documentation for archive_pipeline commands. Terminal stage.
//  With no positional argument, returns the index of all registered
//  filters. With a command name, returns that filter's man page.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESManFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
