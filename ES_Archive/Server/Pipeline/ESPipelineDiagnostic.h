//
//  ESPipelineDiagnostic.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Shared helper for building per-stage pipeline diagnostic lines with
//  command-aware annotations. Each filter constructs its spelling string
//  and calls this with its kind tag.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ESPipelineFilterKind) {
    ESPipelineFilterKindFilter,    ///< grep, discover — selectivity meaningful
    ESPipelineFilterKindRanker,    ///< w2vgrep — re-ranks; selectivity meaningful when narrowed
    ESPipelineFilterKindReorder,   ///< sort — count never changes
    ESPipelineFilterKindSlice,     ///< head, tail — mechanical
    ESPipelineFilterKindCounter,   ///< wc — counts only
    ESPipelineFilterKindReader,    ///< cat — terminal
    ESPipelineFilterKindLfind,     ///< lfind — runs server-side here
    ESPipelineFilterKindUnknown,
};

/// Build a diagnostic line of the form:
///   "lfind --tag X                          → 11 hits"
///   "| w2vgrep "Q"                          → 14 hits  (highly selective: 7%)"
NSString *ESPipelineDiagLine(NSString *spelling,
                              BOOL isFirst,
                              NSArray<NSManagedObjectID *> * _Nullable prior,
                              NSArray<NSManagedObjectID *> *result,
                              ESPipelineFilterKind kind);

/// Render a stage's command spelling from name + positional + flags.
/// Re-quotes values that contain whitespace.
NSString *ESPipelineStageSpelling(NSString *name,
                                   NSArray<NSString *> *positional,
                                   NSDictionary<NSString *, id> *flags);

NS_ASSUME_NONNULL_END
