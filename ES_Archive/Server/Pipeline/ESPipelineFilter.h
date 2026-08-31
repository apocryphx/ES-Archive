//
//  ESPipelineFilter.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Protocol for archive_pipeline filter classes. Each filter is a stage in
//  a Unix-style pipeline (lfind, w2vgrep, grep, head, ...). Filters compose
//  by being chained in an array; ESPipelineExecutor walks the chain.
//
//  Design intent (Core Image-shaped):
//    - Filters are introspectable. Each declares its name, parameter schema,
//      man page text. The executor can ask each filter what it contributes.
//    - Two kinds of filters:
//        * Fusable filters declare predicate/sort/limit contributions. The
//          executor combines contributions across the chain into one
//          NSFetchRequest where possible (Phase 2 optimizer).
//        * Non-fusable filters implement applyToInput: directly. They
//          process the population after the fetch (semantic ranking, NER,
//          graph traversal, etc.) — work that can't be folded into a
//          predicate.
//    - In Phase 1 the executor runs naïvely (apply each filter in order).
//      Phase 2 adds the optimizer that uses contributions.
//
//  Phase 1 only requires the @required methods. The fusion contributions
//  are @optional and unused until Phase 2.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

/// One stage from the pipeline DSL: command name plus positional args and
/// flag dict. Bridge's ESBridgeCLIStage maps directly to this shape.
@interface ESPipelineStage : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSArray<NSString *> *positional;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *flags;

+ (nullable instancetype)stageFromDictionary:(NSDictionary *)dict;
- (instancetype)initWithName:(NSString *)name
                   positional:(NSArray<NSString *> *)positional
                        flags:(NSDictionary<NSString *, id> *)flags;
@end


@protocol ESPipelineFilter <NSObject>
@required

/// Command name as used in the CLI (e.g. "lfind", "w2vgrep", "head").
+ (NSString *)commandName;

/// Initialize a filter instance from a parsed pipeline stage. Returns nil
/// if the stage's parameters are invalid for this filter (errOut populated).
- (nullable instancetype)initWithStage:(ESPipelineStage *)stage
                                  error:(NSError **)errOut;

/// Apply the filter to an input population. Returns the new population.
/// `prior` is nil for the first stage; otherwise the previous filter's
/// output. `ctx` is the Core Data context to use for any fetches.
///
/// Even fusable filters implement this — Phase 1 calls it directly; Phase 2
/// may fold it into a unified fetch when contributions allow.
- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut;

/// Per-stage diagnostic line that goes into the pipeline's diagnostic
/// output. The filter knows its own input/output counts and any annotation
/// it wants to surface.
- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst;

/// The man-page text for this command (NAME, SYNOPSIS, DESCRIPTION,
/// EXAMPLES, DIAGNOSTICS, SEE ALSO sections). Returned verbatim.
+ (NSString *)manPage;


@optional

#pragma mark - Diagnostic policy

/// Filters that don't operate on a population (man, in particular) can
/// return YES here to tell the executor to skip emitting a pipeline
/// diagnostic line for this stage. Default behavior (method absent) is
/// to emit the diagnostic.
+ (BOOL)suppressesPipelineDiagnostic;

/// Filters whose results' meaning depends on temporal proximity (arc is the
/// canonical case — a session-cluster is unintelligible without timestamps)
/// can return YES here to request that the standard render emit a
/// `dateCreated` field on each row. The executor walks all filters in a
/// pipeline at the final render step; if any declares YES, RenderPopulation
/// includes dateCreated. Cheap, additive — preserves the standard
/// title/summary triage shape and stays out of cat's terminal-response path
/// (cat already emits its own dates).
+ (BOOL)requiresDateContext;


#pragma mark - Score advertisement

/// Filters that produce per-result scores (w2vgrep is the canonical case)
/// expose them here. The executor threads these through to the rendered
/// silhouette as a `score` field per row, and propagates the map across
/// downstream filters that only trim the population (head, etc.) without
/// changing scores. Returning nil — or not implementing this method — is
/// the default; the silhouette omits `score` for those rows.
///
/// Map: objectID → @(rawCosine).
- (nullable NSDictionary<NSManagedObjectID *, NSNumber *> *)lastScoreMap;


#pragma mark - Terminal stages

/// Optional. If implemented, the filter is a terminal stage (cat, wc, man)
/// that produces its own response shape rather than threading a population
/// to a successor. The executor calls this on the LAST stage of a pipeline
/// in addition to applyToInput: (which still drives the diagnostic line);
/// the returned dict replaces the default {pipeline, results, count} shape,
/// with `pipeline` re-merged in by the executor.
///
/// Terminal stages should be the last stage of a pipeline; the executor
/// will warn if a non-terminal stage follows a terminal one.
- (nullable NSDictionary *)terminalResponseWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                              context:(NSManagedObjectContext *)ctx
                                                error:(NSError **)errOut;


#pragma mark - Phase 2: fusion contributions

/// Predicate this filter would AND into a unified NSFetchRequest. Return
/// nil if the filter can't be expressed as a predicate (e.g. semantic
/// ranking). Filters that don't implement this are non-fusable.
///
/// `ctx` is passed so the contribution can resolve identifiers to Core
/// Data objects when needed (e.g. lfind looks up the CDTag by name and
/// returns `ANY tags == %@` rather than the index-unfriendly SUBQUERY
/// form). Filters that don't need ctx may simply ignore it.
- (nullable NSPredicate *)predicateContributionWithContext:(NSManagedObjectContext *)ctx;

/// Sort descriptors this filter contributes to a unified fetch. Most
/// filters return nil; sort returns an array.
- (nullable NSArray<NSSortDescriptor *> *)sortDescriptorContribution;

/// Fetch limit this filter would impose on a unified fetch. nil if no
/// limit; otherwise the filter's N (head/tail return this).
- (nullable NSNumber *)fetchLimitContribution;

@end

NS_ASSUME_NONNULL_END
