//
//  ESW2vgrepFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESW2vgrepFilter.h"
#import "ESPipelineDiagnostic.h"
#import "ESVectorEngine.h"
#import "ESVectorSearchResult.h"
#import "CDMemory.h"
#import "CDMemory+CoreDataProperties.h"
#import "CDVector.h"

@implementation ESW2vgrepFilter {
    NSString *_query;
    NSInteger _limit;
    float _threshold;
    NSString * _Nullable _focus;
    ESPipelineStage *_stage;
    NSDictionary<NSManagedObjectID *, NSNumber *> * _Nullable _lastScoreMap;
}

+ (NSString *)commandName { return @"w2vgrep"; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _query = stage.positional.firstObject;
        if (_query.length == 0) {
            if (errOut) {
                *errOut = [NSError errorWithDomain:@"ESPipelineError" code:1
                                          userInfo:@{NSLocalizedDescriptionKey:
                            @"w2vgrep requires a query — try: w2vgrep \"...\""}];
            }
            return nil;
        }

        // Note: short queries (1–4 words) still rank — they're just noisier
        // because the mean-pool embedding doesn't stabilize until the query
        // carries enough natural-language structure. 5+ words is the
        // recommended floor for meaningful threshold filtering, and the man
        // page documents this. We don't reject short queries because the
        // ranking on its own is still useful (e.g. `w2vgrep "X" | head 5`
        // surfaces the closest matches without needing absolute calibration).

        _limit = 200;
        id limitVal = stage.flags[@"limit"];
        if ([limitVal isKindOfClass:NSString.class]) {
            NSInteger v = [(NSString *)limitVal integerValue];
            if (v > 0) _limit = v;
        } else if ([limitVal isKindOfClass:NSNumber.class]) {
            NSInteger v = [(NSNumber *)limitVal integerValue];
            if (v > 0) _limit = v;
        }
        if (_limit < 1) _limit = 1;
        if (_limit > 500) _limit = 500;

        // --threshold / -t : minimum score required to pass. Lives in the
        // same [0, 1] scale as r.score (raw cosine, post-May-6 BGE), so a
        // user reading score 0.8 in a result can type --threshold 0.8 and
        // get results at that quality or better.
        // Default 0 — w2vgrep ranks without filtering.
        //
        // See man page for empirical guidance on useful values.
        _threshold = 0.0f;
        id thrVal = stage.flags[@"threshold"] ?: stage.flags[@"t"];
        if ([thrVal isKindOfClass:NSString.class]) {
            float v = [(NSString *)thrVal floatValue];
            _threshold = v;
        } else if ([thrVal isKindOfClass:NSNumber.class]) {
            _threshold = [(NSNumber *)thrVal floatValue];
        }
        if (_threshold < 0.0f) _threshold = 0.0f;
        if (_threshold > 1.0f) _threshold = 1.0f;

        id focusVal = stage.flags[@"focus"];
        if ([focusVal isKindOfClass:NSString.class] && [(NSString *)focusVal length] > 0) {
            _focus = (NSString *)focusVal;
        }
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    // If a prior population exists, build the allowedVectorIDs set so the
    // engine ranks WITHIN that population (not the full corpus).
    NSSet<NSManagedObjectID *> * _Nullable allowedVectorIDs = nil;

    if (prior) {
        NSFetchRequest *vfetch = [CDMemory fetchRequest];
        vfetch.predicate = [NSPredicate predicateWithFormat:@"SELF IN %@", [NSSet setWithArray:prior]];
        vfetch.includesSubentities = NO;
        vfetch.relationshipKeyPathsForPrefetching = @[@"vector"];
        NSError *vErr = nil;
        NSArray<CDMemory *> *priorMemories = [ctx executeFetchRequest:vfetch error:&vErr];
        if (vErr) {
            if (errOut) *errOut = vErr;
            return @[];
        }

        NSMutableSet<NSManagedObjectID *> *vIDs = [NSMutableSet setWithCapacity:priorMemories.count];
        for (CDMemory *m in priorMemories) {
            CDVector *v = [m vectorForActiveEmbedder];
            if (v) [vIDs addObject:v.objectID];
        }
        if (vIDs.count == 0) return @[];  // no embedded memories in prior
        allowedVectorIDs = vIDs;
    }

    NSArray<ESVectorSearchResult *> *results =
        [[ESVectorEngine shared] searchWithQuery:_query
                                            limit:_limit
                                       decayLevel:_focus
                                 allowedVectorIDs:allowedVectorIDs];

    // Threshold filter: r.score IS raw cosine similarity (pre-decay). The
    // caller-supplied threshold is on the same scale. A user who reads
    // "score: 0.85" in a result and wants results at-this-quality-or-better
    // can pass --threshold 0.85 directly.
    //
    // Decay-weighting only affects ranking, not the threshold cutoff, so
    // older memories aren't penalized for being old.
    //
    // A threshold of 0.0 retains every result (default).
    NSMutableArray<NSManagedObjectID *> *ids = [NSMutableArray arrayWithCapacity:results.count];
    NSMutableDictionary<NSManagedObjectID *, NSNumber *> *scoreMap =
        [NSMutableDictionary dictionaryWithCapacity:results.count];
    for (ESVectorSearchResult *r in results) {
        if (r.score < _threshold) continue;
        NSManagedObjectID *oid = r.memory.objectID;
        if (!oid) continue;
        [ids addObject:oid];
        scoreMap[oid] = @(r.score);
    }
    _lastScoreMap = [scoreMap copy];
    return ids;
}

- (nullable NSDictionary<NSManagedObjectID *, NSNumber *> *)lastScoreMap {
    return _lastScoreMap;
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);

    // Compose a bracket annotation with up to two parts:
    //
    //   t=N                      effective threshold when the caller didn't
    //                            set it explicitly (otherwise the spelling
    //                            already echoes --threshold N)
    //   short query unreliable, use grep
    //                            warning when the query is below the
    //                            recommended 5-word floor; the embedding
    //                            mean-pool is noisy for short input so
    //                            both ranking and threshold are unreliable.
    //                            "use grep" gives the right next move
    //                            without making the reader interpret —
    //                            for keyword queries, that's the answer.
    //
    // Putting the warning in the diagnostic itself, at the point of failure,
    // beats burying it in the man page. A user who runs `w2vgrep "branching"
    // | head 5` sees the warning AND the redirect on the same line.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    BOOL thresholdExplicit = (_stage.flags[@"threshold"] != nil) || (_stage.flags[@"t"] != nil);
    if (!thresholdExplicit) {
        [parts addObject:[NSString stringWithFormat:@"t=%g", _threshold]];
    }

    NSArray<NSString *> *words = [_query componentsSeparatedByCharactersInSet:
                                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger wordCount = 0;
    for (NSString *w in words) {
        if (w.length > 0) wordCount++;
    }
    if (wordCount < 5) {
        [parts addObject:@"short query unreliable, use grep"];
    }

    if (parts.count > 0) {
        spelling = [NSString stringWithFormat:@"%@ [%@]",
                    spelling,
                    [parts componentsJoinedByString:@", "]];
    }

    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindRanker);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    w2vgrep — semantic concept search\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    w2vgrep \"<concept phrase, 5+ words recommended>\"\n"
        @"            [-t N | --threshold N] [--limit N]\n"
        @"            [--focus day|week|month|none]\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    Semantic concept search via vector cosine similarity. The query\n"
        @"    should be a natural-language phrase or short paragraph describing\n"
        @"    the *concept* you're looking for, not a keyword to match.\n"
        @"\n"
        @"    THIS IS NOT A GREP. w2vgrep doesn't find entries that contain\n"
        @"    your query string; it finds entries whose embedding vector is\n"
        @"    semantically close to your query's embedding vector.\n"
        @"\n"
        @"    Query length matters. The mean-pool embedding is noisy for\n"
        @"    short inputs (1–4 words) and only becomes a reliable concept\n"
        @"    signal once the query carries enough natural-language structure\n"
        @"    to land near the text-embedding centroid. Short queries still\n"
        @"    *rank* (so `w2vgrep \"X\" | head 5` is fine for casual probes),\n"
        @"    but the --threshold knob is only meaningful for 5+ word\n"
        @"    queries. Below that, threshold values are unstable and you'll\n"
        @"    spend time tuning a number that doesn't behave consistently.\n"
        @"\n"
        @"    Use the right tool for the job:\n"
        @"        keyword / substring / proper noun  →  grep \"text\"\n"
        @"        curated handle (subset/project/…) →  lfind --tag \"Name\"\n"
        @"        all tags of a kind                →  lfind --tag-kind project\n"
        @"        recent or by author                →  lfind --days N / --author X\n"
        @"        semantic concept                   →  w2vgrep \"phrase about ...\"\n"
        @"\n"
        @"    When piped from a previous stage, ranks within that population.\n"
        @"    Otherwise ranks over the full corpus. By default w2vgrep ranks\n"
        @"    without filtering — same behavior as archive_search. Use head N\n"
        @"    to take the top N most similar:\n"
        @"\n"
        @"        lfind --tag \"ES Archive\"\n"
        @"            | w2vgrep \"how memory branching and refinement compose\"\n"
        @"            | head 10\n"
        @"\n"
        @"OPTIONS\n"
        @"    -t, --threshold N   Minimum scaled score required to pass.\n"
        @"                        Lives on the SAME [0, 1] scale as the\n"
        @"                        `score` field in results — read a score\n"
        @"                        in a result, pass that number as the\n"
        @"                        threshold, get results at that quality\n"
        @"                        or better. No mental conversion needed.\n"
        @"\n"
        @"                        Default 0.0 (no filtering — pure re-rank).\n"
        @"\n"
        @"                        Useful values for concept queries (5–30\n"
        @"                        word phrases) in this Archive:\n"
        @"                            0.10  noise floor — random text scores here\n"
        @"                            0.35  broadly related concept\n"
        @"                            0.48  clearly the same concept\n"
        @"                            0.60  strong match — multiple axes\n"
        @"                            0.80+ near-duplicate — query mirrors a summary\n"
        @"                        Below ~0.30 the filter is into the natural-\n"
        @"                        text noise floor (random text scores ~0.05-\n"
        @"                        0.10), so ~0.45 is the practical lower bound\n"
        @"                        for meaningful narrowing.\n"
        @"\n"
        @"    --limit N           Cap on candidates considered (default 200,\n"
        @"                        max 500). The threshold filter, if any,\n"
        @"                        applies to these candidates.\n"
        @"    --focus             Temporal weighting override (day | week |\n"
        @"                        month | none).\n"
        @"\n"
        @"INTERPRETING SCORES\n"
        @"    The score is a composite signal — multiple matching axes can\n"
        @"    fire simultaneously: topic, register/tone, vocabulary cluster,\n"
        @"    lexical anchor, conceptual analogy. A high score doesn't tell\n"
        @"    you which axis is firing; the result content does. A 0.85\n"
        @"    result might be a topical match (about the same thing) OR a\n"
        @"    register-only match (same tone, different topic). Both are\n"
        @"    useful in different ways.\n"
        @"\n"
        @"    The shape of the top-N is diagnostic too:\n"
        @"        Standout (one above a tight cluster)  →  unique deep match\n"
        @"                                                 in the Archive\n"
        @"        Smooth gradient (top-10 within 0.02)  →  broad theme deeply\n"
        @"                                                 represented; many\n"
        @"                                                 entries match\n"
        @"                                                 near-equally\n"
        @"\n"
        @"    Cluster gravity is real. An entry at the intersection of small\n"
        @"    clusters is findable in its native register but invisible from\n"
        @"    adjacent registers, no matter how well its summary is shaped.\n"
        @"    The Archive's dense clusters absorb queries in their range.\n"
        @"\n"
        @"    Entry-vs-entry comparisons (archive_read's similar list,\n"
        @"    archive_store's flare) run higher than query-string scores\n"
        @"    because both vectors are full-summary embeddings — 0.95+ is\n"
        @"    normal there for genuinely related neighbors. For w2vgrep,\n"
        @"    0.95+ usually means the query closely mirrors a stored summary.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    Concept search across a tagged population:\n"
        @"        lfind --tag \"ES Archive\"\n"
        @"            | w2vgrep \"agentic retry logic for failed searches\"\n"
        @"            | head 10\n"
        @"\n"
        @"    Filter to clearly-related results only:\n"
        @"        w2vgrep \"persistent memory architecture for AI agents\"\n"
        @"            --threshold 0.8\n"
        @"            | head 5\n"
        @"\n"
        @"    Recent entries on a concept:\n"
        @"        lfind --days 7\n"
        @"            | w2vgrep \"vector similarity threshold tuning\"\n"
        @"            | head 5\n"
        @"\n"
        @"DIAGNOSTICS\n"
        @"    (highly selective: X%%) means significant narrowing — only when\n"
        @"    --threshold is set.\n"
        @"    [t=0] in the trace means no threshold was set (default). Pass\n"
        @"    --threshold > 0 to filter at this stage; otherwise downstream\n"
        @"    `head N` does the narrowing.\n"
        @"    [short query unreliable, use grep] means the query is under 5\n"
        @"    words. The mean-pool embedding is noisy at that length and the\n"
        @"    ranking can't be trusted. The redirect points at grep because\n"
        @"    that's the right tool for keyword/substring matching, including\n"
        @"    proper nouns (tags are curated handles now, not auto-extracted\n"
        @"    proper nouns — grep is the right substring tool). Or expand the\n"
        @"    query to a 5+ word concept phrase to use w2vgrep meaningfully.\n"
        @"\n"
        @"SEE ALSO\n"
        @"    grep, lfind, head\n";
}

@end
