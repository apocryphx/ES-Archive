//
//  ESTagPipelineFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  tag — pipeline write filter. Attaches a named tag to every memory in
//  the input population. The tag must already exist (curated layer, no
//  auto-create). Atomic: a single Core Data save covers all attachments.
//
//  Convention break: pipeline filters are typically read-only. This one
//  writes. Composing curatorial gestures through the pipeline (e.g.
//  `grep X | grep Y | tag "Subset Name"`) was deemed worth the break.
//

#import <Foundation/Foundation.h>
#import "ESPipelineFilter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ESTagPipelineFilter : NSObject <ESPipelineFilter>
@end

NS_ASSUME_NONNULL_END
