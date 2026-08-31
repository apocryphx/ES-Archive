//
//  ESPipelineExecutor.h
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//
//  Executes a parsed pipeline by instantiating the right filter class
//  per stage, walking the chain, and accumulating per-stage diagnostics
//  into a final response dict.
//
//  Phase 1: naïve sequential execution. Each filter's applyToInput: is
//  called in order; the population threads through.
//
//  Phase 2 (planned): two-pass with fusion. Walk for predicate/sort/limit
//  contributions; combine fusable filters into one NSFetchRequest;
//  apply non-fusable filters after.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

/// Look up the filter class registered for a given command name.
/// Returns nil if the command is unknown.
Class _Nullable ESPipelineFilterClassForCommand(NSString *commandName);

/// All filter classes registered in the pipeline. Used by `man` to render
/// the index, and by the executor to dispatch.
NSArray<Class> *ESPipelineRegisteredFilterClasses(void);

/// Execute a pipeline. `stages` is an array of dicts, each with shape
/// {name: string, positional: [string]?, flags: {string: any}?}.
/// Returns the response dict that archive_pipeline tool serializes.
///
/// Response shape on success:
///   {
///     "pipeline":  "<per-stage diagnostic lines joined by \\n>",
///     "results":   [{ title, score?, summary?, ... }, ...],
///     "count":     N
///   }
///
/// Response shape for terminal stages (cat, wc, man) overrides results
/// with their own shape (e.g. {man: "..."} or {count: N}).
///
/// Error shape:
///   { "error": "...", "message": "...", "pipeline": "..." }
///
/// `scopeAuthor` is the connecting persona's identity. The executor seeds the
/// initial population with that persona's memories, so every filter that
/// respects `prior` (all of them) inherits the scope structurally, and the
/// final population is intersected with the scope as a backstop. An explicit
/// `lfind --author` that differs from `scopeAuthor` is rejected.
NSDictionary *ESPipelineExecute(NSArray<NSDictionary *> *stages,
                                 NSManagedObjectContext *ctx,
                                 NSString *scopeAuthor);

NS_ASSUME_NONNULL_END
