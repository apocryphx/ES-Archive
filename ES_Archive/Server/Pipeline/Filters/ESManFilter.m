//
//  ESManFilter.m
//  ES Archive
//
//  Copyright © 2026 Kolja Wawrowsky. All rights reserved.
//  Licensed under the MIT License. See LICENSE file in the project root.
//

#import "ESManFilter.h"
#import "ESPipelineDiagnostic.h"
#import "ESPipelineExecutor.h"

@implementation ESManFilter {
    ESPipelineStage *_stage;
    NSString * _Nullable _target;
}

+ (NSString *)commandName { return @"man"; }

#pragma mark - Topic pages

// Topics are man pages that aren't tied to a real filter class — meta-
// documentation about how to compose the system. They live alongside the
// command pages in the man system: `man pipelines` returns this text just
// like `man w2vgrep` returns the w2vgrep filter's manPage. The index lists
// them in their own section so users can discover them without grepping.
//
// Keep keys lowercase, single-word; the lookup is case-sensitive.
+ (NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)topicPages {
    static NSDictionary *topics;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        topics = @{
            @"tags": @{
                @"synopsis": @"the curated tag layer: kinds, lifecycle, staging intermediate results",
                @"page":
                    @"NAME\n"
                    @"    tags — the curated tag layer: kinds, lifecycle, and how to stage\n"
                    @"           intermediate search results as durable subsets\n"
                    @"\n"
                    @"DESCRIPTION\n"
                    @"    The tag layer is deliberately authored, not auto-extracted —\n"
                    @"    the system itself never tags anything. Every tag exists because\n"
                    @"    AI created it, through one of two paths: deliberate provisioning\n"
                    @"    via the archive_tags tool (mode=create — sets kind and expiry up\n"
                    @"    front), or connect-or-create on archive_store / archive_tag, which\n"
                    @"    mints unknown names with kind 'thing'. Prefer provisioning;\n"
                    @"    connect-or-create is for quick handles. Tags carry curatorial\n"
                    @"    signal that grep can't: \"this entry belongs to this set\" is\n"
                    @"    a judgment, not a substring match.\n"
                    @"\n"
                    @"    Three practical implications:\n"
                    @"\n"
                    @"      1. A proper noun in body text does NOT imply a matching tag.\n"
                    @"         For exact-name retrieval, use grep. Use lfind --tag only\n"
                    @"         for handles you (or a previous AI) deliberately\n"
                    @"         created.\n"
                    @"\n"
                    @"      2. Tag creation is a small ritual: create → attach → use →\n"
                    @"         eventually retire. The friction is the point.\n"
                    @"\n"
                    @"      3. The kind taxonomy is descriptive only. It does NOT drive\n"
                    @"         expiration. Set dateExpired (via expiresAt at creation,\n"
                    @"         or archive_tags mode=update newExpiresAt later) explicitly\n"
                    @"         when you want it.\n"
                    @"\n"
                    @"KINDS\n"
                    @"\n"
                    @"        person       named individuals (rarely expire)\n"
                    @"        place        named locations\n"
                    @"        project      structural project membership (e.g. \"ES Archive\")\n"
                    @"        principle    concept handles distinctive enough to anchor\n"
                    @"                     (e.g. \"Erwinkel Test\", \"score-axis ladder\")\n"
                    @"        subset       authored anthology — \"Isolde's Stories\"\n"
                    @"        session      working session collaboration (usually expires)\n"
                    @"        research     active research-result grouping (usually expires)\n"
                    @"        thing        uncategorized default — what connect-or-create\n"
                    @"                     (archive_store / archive_tag) mints for unknown names\n"
                    @"\n"
                    @"    Person/place/project/principle/subset typically have no\n"
                    @"    expiration. Session and research typically do — they're\n"
                    @"    workspaces, not durable categories.\n"
                    @"\n"
                    @"STAGING INTERMEDIATE RESULTS\n"
                    @"\n"
                    @"    The pipeline write filters (tag, untag) make a search-result\n"
                    @"    population persistable in one atomic gesture. When a query\n"
                    @"    produces a useful set you'll want to revisit, refine, or\n"
                    @"    iterate over — not a one-off — materialize it as a tag.\n"
                    @"\n"
                    @"        archive_tags(mode=create, name=\"score-calibration\", kind=research, expiresAt=\"+30 days\")\n"
                    @"        discover --mode forgotten | w2vgrep \"score scaling\" | tag \"score-calibration\"\n"
                    @"\n"
                    @"    Now you have a stable handle for that population, independent\n"
                    @"    of recency drift or vector-engine recalibration:\n"
                    @"\n"
                    @"        lfind --tag \"score-calibration\" | w2vgrep \"anisotropy floor\" | head 5\n"
                    @"        lfind --tag \"score-calibration\" | sort popular | head 10\n"
                    @"        lfind --tag \"score-calibration\" | wc          # how big is it?\n"
                    @"\n"
                    @"    When the work ends, the tag retires itself (expires past the\n"
                    @"    horizon you set). If it continues, archive_tags mode=update\n"
                    @"    (newExpiresAt) pushes the horizon out — the population stays\n"
                    @"    intact.\n"
                    @"\n"
                    @"WHEN TO STAGE\n"
                    @"\n"
                    @"    Stage as a tag when:\n"
                    @"      - You'll refine the result with multiple downstream queries\n"
                    @"      - Composition involves slow ops (large w2vgrep, repeated)\n"
                    @"      - The population represents a deliberate curatorial choice\n"
                    @"      - Ephemeral, time-boxed work that should self-clean\n"
                    @"      - The query is hard to reproduce verbatim later\n"
                    @"\n"
                    @"    Don't stage when:\n"
                    @"      - One-off retrieval (just rerun the pipeline)\n"
                    @"      - Substring matching by proper noun (grep is the right tool)\n"
                    @"      - Pairwise relationships (use archive_link)\n"
                    @"      - Categorical labels with vocabulary-drift risk (\"important\",\n"
                    @"        \"philosophical\", \"technical\") — these degrade to noise.\n"
                    @"        Distinctive subset names are durable; folksonomies aren't.\n"
                    @"\n"
                    @"LIFECYCLE PATTERNS\n"
                    @"\n"
                    @"    Persistent curated subset (no expiration)\n"
                    @"        archive_tags(mode=create, name=\"Isoldes Stories\", kind=subset)\n"
                    @"        grep \"Isolde\" | grep \"Myth\" | tag \"Isoldes Stories\"\n"
                    @"\n"
                    @"    Today's session, expiring tomorrow\n"
                    @"        archive_tags(mode=create, name=\"session-2026-05-04\", kind=session, expiresAt=\"+24h\")\n"
                    @"        lfind --days 1 | tag \"session-2026-05-04\"\n"
                    @"        # ... work happens, session ends, tag self-retires\n"
                    @"\n"
                    @"    Session that grew into something\n"
                    @"        archive_tags(mode=update, name=\"session-2026-05-04\", newExpiresAt=\"+30 days\")\n"
                    @"        # population intact, horizon pushed; reconsider kind:\n"
                    @"        # archive_tags(mode=update, name=\"session-2026-05-04\", newKind=research)\n"
                    @"\n"
                    @"    Research thread, time-boxed at one month\n"
                    @"        archive_tags(mode=create, name=\"hot-path-investigation\", kind=research, expiresAt=\"+30 days\")\n"
                    @"        discover --mode forgotten | w2vgrep \"hot path\" | tag \"hot-path-investigation\"\n"
                    @"\n"
                    @"    Move a curated set under a clearer name\n"
                    @"        archive_tags(mode=create, name=\"Subset-v2\", kind=subset)\n"
                    @"        lfind --tag \"Subset-v1\" | untag \"Subset-v1\" | tag \"Subset-v2\"\n"
                    @"        archive_tags(mode=delete, name=\"Subset-v1\")\n"
                    @"\n"
                    @"VISIBILITY\n"
                    @"\n"
                    @"    Expired tags are hidden by default in lfind --tag and --tag-kind\n"
                    @"    queries. They aren't deleted — the join row stays — they just\n"
                    @"    drop out of read traffic. Three ways to see them:\n"
                    @"\n"
                    @"        lfind --tag X --include-expired                    # this filter only\n"
                    @"        archive_tags(mode=list, includeExpired=true)        # the catalog\n"
                    @"        archive_tags(mode=update, name=X, newExpiresAt=...) # bring back to life\n"
                    @"\n"
                    @"ANTI-PATTERNS\n"
                    @"\n"
                    @"    - Treating tags like grep results. Auto-extraction is gone for\n"
                    @"      a reason: grep already does substring matching. Tags carry\n"
                    @"      a different signal — \"belongs to this curated set\".\n"
                    @"\n"
                    @"    - Per-conversation session tags that get deleted at end-of-\n"
                    @"      session. Expire instead of delete; let the Archive show\n"
                    @"      what was active when, with --include-expired.\n"
                    @"\n"
                    @"    - Generic category tags (\"technical\", \"important\"). Vocabulary\n"
                    @"      drift turns these into noise. Use distinctive subset names\n"
                    @"      that name the actual cluster: \"Wetzlar pre-merger discussion\",\n"
                    @"      not \"important\".\n"
                    @"\n"
                    @"    - Leaning on connect-or-create for durable sets. The pipeline\n"
                    @"      tag/untag filters and archive_update refuse unknown tag names;\n"
                    @"      archive_store and archive_tag mint them silently as kind 'thing'.\n"
                    @"      When kind or expiry matters, provision deliberately with\n"
                    @"      archive_tags mode=create before tagging.\n"
                    @"\n"
                    @"SEE ALSO\n"
                    @"    man tag, man untag, man lfind, man pipelines\n",
            },
            @"pipelines": @{
                @"synopsis": @"composing archive_cli commands into retrieval chains",
                @"page":
                    @"NAME\n"
                    @"    pipelines — composing archive_cli commands into retrieval chains\n"
                    @"\n"
                    @"SYNOPSIS\n"
                    @"    <stage> | <stage> | ... | head N\n"
                    @"\n"
                    @"DESCRIPTION\n"
                    @"    archive_cli commands are orthogonal axes over the same population.\n"
                    @"    A pipeline narrows that population one stage at a time. Each stage\n"
                    @"    receives the output of the previous stage as its input set.\n"
                    @"\n"
                    @"    Read axes:\n"
                    @"\n"
                    @"        w2vgrep   semantic — concept similarity via vector cosine\n"
                    @"        grep      lexical  — literal substring match\n"
                    @"        lfind     enumerative / temporal — tag, kind, recency filter\n"
                    @"        discover  structural — Archive-introspective modes\n"
                    @"        sort      ordering  — reorder a population by a named axis\n"
                    @"        links     graph traversal — neighbors of an input population\n"
                    @"        revisions narrowing — entries whose revision count meets N\n"
                    @"\n"
                    @"    Write axes (mutate associations, then pass the population through):\n"
                    @"\n"
                    @"        tag       attach an existing tag to every entry in the pipeline\n"
                    @"        untag     detach a tag from every entry in the pipeline\n"
                    @"\n"
                    @"    Stages compose in any order. Different orderings expose different\n"
                    @"    cross-sections of the Archive — when one disappoints, try the reverse\n"
                    @"    before concluding the Archive is empty.\n"
                    @"\n"
                    @"    head N always goes last to cap output. Without it, large populations\n"
                    @"    are returned in full.\n"
                    @"\n"
                    @"    tag/untag are write filters: they look up the named tag (which must\n"
                    @"    already exist — provision via archive_tags mode=create), mutate every input entry's\n"
                    @"    tag set in a single Core Data transaction, and pass the population\n"
                    @"    through unchanged so further stages can compose. Use them to commit\n"
                    @"    a curatorial gesture against a search-result set in one atomic call.\n"
                    @"\n"
                    @"CANONICAL PATTERNS\n"
                    @"\n"
                    @"    Concept within an entity\n"
                    @"        lfind --tag \"Name\" | w2vgrep \"concept phrase five or more words\" | head 10\n"
                    @"\n"
                    @"        What has been said about this concept in the context of this\n"
                    @"        person or project. The w2vgrep stage ranks within the tagged\n"
                    @"        population, not the full corpus. Reversing the order —\n"
                    @"        w2vgrep first, then lfind --tag — is a different query: it\n"
                    @"        finds the tag within the top semantic matches. Compare both\n"
                    @"        when the first disappoints.\n"
                    @"\n"
                    @"    Project arc, recently\n"
                    @"        lfind --tag \"Project\" | lfind --days 14 | head 10\n"
                    @"\n"
                    @"        What has been moving in this territory lately. Reverse order —\n"
                    @"        lfind --days 14 | lfind --tag \"Project\" — gives the project's\n"
                    @"        items within the last fortnight's general activity. The two are\n"
                    @"        not the same set.\n"
                    @"\n"
                    @"    Phrase within a project\n"
                    @"        lfind --tag \"Project\" | grep \"exact phrase\" | head 10\n"
                    @"\n"
                    @"        A literal string anchored to a project scope. Use when the phrase\n"
                    @"        is the load-bearing element. Reverse when the phrase is rare and\n"
                    @"        the project is large — grep first, lfind --tag second is faster.\n"
                    @"\n"
                    @"    Buried-signal recovery\n"
                    @"        discover --mode forgotten | w2vgrep \"concept phrase\" | head 10\n"
                    @"\n"
                    @"        The most powerful pattern in the toolkit. Surfaces concept-relevant\n"
                    @"        entries that ordinary semantic search depresses because they are\n"
                    @"        rarely accessed. Try this before concluding the Archive has nothing\n"
                    @"        on a topic. Also works with --mode lost for unlinked orphans.\n"
                    @"\n"
                    @"    Portrait by access\n"
                    @"        lfind --tag \"Name\" | sort --by popular | head 10\n"
                    @"\n"
                    @"        The most-read entries about a person or project — a portrait of\n"
                    @"        how they live in the Archive. Swap sort --by recent for a portrait\n"
                    @"        of what keeps changing (sort by recent keys on dateModified,\n"
                    @"        which revisions bump).\n"
                    @"\n"
                    @"    Drill into conceptual space\n"
                    @"        w2vgrep \"broad concept phrase\" | w2vgrep \"narrowing phrase\" | head 5\n"
                    @"\n"
                    @"        Same-method refinement across two semantic dimensions. Use when no\n"
                    @"        proper noun anchors exist but you want to narrow into a sub-region\n"
                    @"        of meaning. Each stage re-ranks the surviving population.\n"
                    @"\n"
                    @"    Curatorial gesture — author a subset from search\n"
                    @"        archive_tags(mode=create, name=\"Isoldes Stories\", kind=subset)\n"
                    @"        grep \"Isolde\" | grep \"Myth\" | tag \"Isoldes Stories\" | head 10\n"
                    @"\n"
                    @"        Build a stable curated anthology from a literal+literal narrowing.\n"
                    @"        The first call provisions the tag; the pipeline applies it atomically\n"
                    @"        to every match and passes the same population through head so you can\n"
                    @"        inspect what landed. Use kind=subset for authored anthologies, kind=\n"
                    @"        session/research for ephemeral working sets (set expiresAt on\n"
                    @"        creation; extend with archive_tags mode=update newExpiresAt if\n"
                    @"        work continues).\n"
                    @"\n"
                    @"    Move a curated set\n"
                    @"        lfind --tag \"old-name\" | untag \"old-name\" | tag \"new-name\"\n"
                    @"\n"
                    @"        Detach and re-attach in one pipeline. Both writes commit atomically\n"
                    @"        per stage, and the pass-through means each stage sees the full\n"
                    @"        population. Useful when refactoring a subset boundary.\n"
                    @"\n"
                    @"    Session start\n"
                    @"        lfind --days 7 | sort --by recent | head 10\n"
                    @"\n"
                    @"        What is new. Creation date is the signal for newness — sort --by\n"
                    @"        recent surfaces the freshest items first. Follow with:\n"
                    @"\n"
                    @"        discover --mode hot | head 10\n"
                    @"\n"
                    @"        to catch older entries that have become newly active through\n"
                    @"        recent access or linking. The two queries are complementary:\n"
                    @"        one finds new items, the other finds reactivated ones.\n"
                    @"\n"
                    @"    Contradiction and revision audit\n"
                    @"        lfind --days 30 | revisions --min 3 | sort recent | head 10\n"
                    @"\n"
                    @"        Living documents in recent activity — entries whose thinking has\n"
                    @"        been revised substantially in the last month. Read these when\n"
                    @"        you suspect a conclusion has been overturned. The revisions\n"
                    @"        filter narrows to entries whose revision count meets a\n"
                    @"        threshold; sort recent orders by most-recently-edited.\n"
                    @"\n"
                    @"    Walk the disagreement subgraph\n"
                    @"        discover --mode revised | head 20\n"
                    @"            | links --edges \"contradicts,disputes,corrects,revises\"\n"
                    @"            | head 10\n"
                    @"\n"
                    @"        From the most-edited entries, traverse to whatever questions\n"
                    @"        them. The links filter takes a population and emits its graph\n"
                    @"        neighbors filtered by edge type — here, only the questioning\n"
                    @"        edges, so the result is the population that contradicts /\n"
                    @"        disputes / corrects / revises the input. This is the dissent\n"
                    @"        graph in one composition.\n"
                    @"\n"
                    @"RETRY STRATEGY\n"
                    @"\n"
                    @"    If a pipeline returns weak or empty results:\n"
                    @"\n"
                    @"    1. Reorder the stages. lfind --tag X | w2vgrep \"Y\" and\n"
                    @"       w2vgrep \"Y\" | lfind --tag X intersect differently.\n"
                    @"\n"
                    @"    2. Broaden the w2vgrep phrase. Add context — who, what, why.\n"
                    @"       Shorter phrases embed noisily; longer ones land more reliably.\n"
                    @"\n"
                    @"    3. Lower or remove --threshold. A threshold of 0.5 that returns\n"
                    @"       nothing may return good results at 0.4.\n"
                    @"\n"
                    @"    4. Switch the structural entry point. discover --mode forgotten\n"
                    @"       surfaces signal that recency-weighted search buries. Run the\n"
                    @"       same semantic query against forgotten before concluding the\n"
                    @"       Archive is empty.\n"
                    @"\n"
                    @"    5. Replace w2vgrep with grep for proper nouns or exact phrases.\n"
                    @"       The vector model is not a substring matcher.\n"
                    @"\n"
                    @"    A failed pipeline is information about the chain, not the Archive.\n"
                    @"\n"
                    @"READING SCORES\n"
                    @"\n"
                    @"    Scores are raw cosine similarity. The threshold knob and the\n"
                    @"    score field share that scale, so you can read a score and\n"
                    @"    threshold against it directly. Multilingual embedder\n"
                    @"    (EmbeddingGemma, 768-d); a query and a stored summary carry\n"
                    @"    different task prefixes, so even a verbatim match tops out\n"
                    @"    near 0.85-0.90, not 1.0. Empirically calibrated:\n"
                    @"\n"
                    @"        0.80+   source entry or near-twin (rare; query mirrors\n"
                    @"                a stored summary)\n"
                    @"        0.60+   strong match — usually multiple axes (topic +\n"
                    @"                register, or topic + register + vocabulary)\n"
                    @"        0.48+   clearly relevant — same concept, single axis often\n"
                    @"        0.35+   marginal — one axis firing weakly\n"
                    @"        below   noise floor (random text scores ~0.05-0.10)\n"
                    @"\n"
                    @"    Score is a composite signal — topic, register/tone, vocabulary\n"
                    @"    cluster, lexical anchor, conceptual analogy can all fire. The\n"
                    @"    score doesn't tell you which axis is firing; the result\n"
                    @"    content does. A 0.60 result might be the same topic OR the\n"
                    @"    same tone in a different topic — both useful, in different\n"
                    @"    ways. See `man w2vgrep` for the longer treatment.\n"
                    @"\n"
                    @"    Top-N shape is also diagnostic. Standout (one above a tight\n"
                    @"    cluster) means unique deep match. Smooth gradient (top-10\n"
                    @"    within 0.02) means broad theme deeply represented in the\n"
                    @"    Archive — many neighbors match near-equally.\n"
                    @"\n"
                    @"NOTES\n"
                    @"\n"
                    @"    discover is a structural lens on the Archive itself, not a filter\n"
                    @"    over a population. It cannot receive piped input — placing it\n"
                    @"    mid-pipeline will not narrow by a prior stage's output and may\n"
                    @"    produce unexpected results. Always place discover first.\n"
                    @"\n"
                    @"    sort does not filter — it reorders. Always follow with head N.\n"
                    @"\n"
                    @"    w2vgrep --threshold filters; head N truncates. They are not\n"
                    @"    equivalent. Threshold removes low-scoring results regardless of\n"
                    @"    rank; head takes the top N regardless of score.\n"
                    @"\n"
                    @"SEE ALSO\n"
                    @"    man w2vgrep, man lfind, man discover, man grep, man sort,\n"
                    @"    man tag, man untag, man links, man revisions\n",
            },
        };
    });
    return topics;
}

// man is informational, not a population operator. Skip its diagnostic line.
+ (BOOL)suppressesPipelineDiagnostic { return YES; }

- (instancetype)initWithStage:(ESPipelineStage *)stage error:(NSError **)errOut {
    self = [super init];
    if (self) {
        _stage = stage;
        _target = stage.positional.firstObject;
    }
    return self;
}

- (NSArray<NSManagedObjectID *> *)applyToInput:(nullable NSArray<NSManagedObjectID *> *)prior
                                        context:(NSManagedObjectContext *)ctx
                                          error:(NSError **)errOut {
    return @[];  // man doesn't operate on a population
}

- (NSDictionary *)terminalResponseWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                      context:(NSManagedObjectContext *)ctx
                                        error:(NSError **)errOut {
    if (_target.length == 0) {
        // Index: list every registered filter with a one-line synopsis from
        // its man page (line 2 typically — the "NAME" line is the synopsis).
        NSArray<Class> *classes = ESPipelineRegisteredFilterClasses();
        NSMutableString *index = [NSMutableString string];
        [index appendString:@"Available commands:\n"];

        // Build a sorted list of (name, synopsis) pairs. Synopsis is parsed
        // from the man page's "NAME" section (the line after "NAME\n").
        for (Class cls in classes) {
            NSString *name = [cls performSelector:@selector(commandName)];
            NSString *page = [cls performSelector:@selector(manPage)];
            NSString *synopsis = @"";

            // Extract the line after "    " under "NAME"
            NSRange nameMarker = [page rangeOfString:@"NAME\n"];
            if (nameMarker.location != NSNotFound) {
                NSUInteger start = NSMaxRange(nameMarker);
                NSRange newline = [page rangeOfString:@"\n" options:0
                                                 range:NSMakeRange(start, page.length - start)];
                if (newline.location != NSNotFound) {
                    NSString *line = [page substringWithRange:NSMakeRange(start, newline.location - start)];
                    line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    // Format: "name — description"; take everything after "— "
                    NSRange dash = [line rangeOfString:@"— "];
                    if (dash.location != NSNotFound) {
                        synopsis = [line substringFromIndex:NSMaxRange(dash)];
                    } else {
                        synopsis = line;
                    }
                }
            }
            // %-10@ width modifier on NSString format specifiers is silently
            // ignored, so pad manually to keep the index aligned.
            NSString *paddedName = [name stringByPaddingToLength:10
                                                      withString:@" "
                                                 startingAtIndex:0];
            [index appendFormat:@"  %@ %@\n", paddedName, synopsis];
        }

        // Topic pages section (composition guides, design notes, etc. that
        // aren't tied to a single command). Sorted alphabetically.
        NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *topics =
            [ESManFilter topicPages];
        if (topics.count > 0) {
            [index appendString:@"\nTopics:\n"];
            NSArray<NSString *> *topicNames =
                [topics.allKeys sortedArrayUsingSelector:@selector(compare:)];
            for (NSString *t in topicNames) {
                NSString *synopsis = topics[t][@"synopsis"] ?: @"";
                NSString *paddedTopic = [t stringByPaddingToLength:10
                                                        withString:@" "
                                                   startingAtIndex:0];
                [index appendFormat:@"  %@ %@\n", paddedTopic, synopsis];
            }
        }

        [index appendString:@"\n"];
        [index appendString:@"Pipelines compose with |. The output of each stage feeds the next.\n"];
        [index appendString:@"Try 'man pipelines' for canonical patterns and retry strategy,\n"];
        [index appendString:@"or 'man <command>' for any specific command.\n\n"];
        [index appendString:@"If results disappoint, vary the pipeline: reorder stages, replace one\n"];
        [index appendString:@"command with another at the same position, or change a parameter and\n"];
        [index appendString:@"re-run. Be persistent. Be creative. You will find it eventually.\n"];

        return @{ @"man": [index copy] };
    }

    // Specific page lookup.
    // Check topic pages first — if a future filter ever has a name colliding
    // with a topic, the filter wins (more specific affordance), so we look
    // it up in the registry before falling through to topics. In practice
    // topic names are reserved and won't collide.
    Class cls = ESPipelineFilterClassForCommand(_target);
    if (cls) {
        NSString *page = [cls performSelector:@selector(manPage)];
        return @{ @"man": page ?: @"(no man page available)" };
    }

    NSDictionary<NSString *, NSString *> *topic = [ESManFilter topicPages][_target];
    if (topic[@"page"]) {
        return @{ @"man": topic[@"page"] };
    }

    return @{
        @"error":   @"unknown_command",
        @"message": [NSString stringWithFormat:
            @"no man page for '%@'. Try 'man' to see what's available.", _target],
    };
}

- (NSString *)diagnosticLineWithPrior:(nullable NSArray<NSManagedObjectID *> *)prior
                                result:(NSArray<NSManagedObjectID *> *)result
                                isFirst:(BOOL)isFirst {
    NSString *spelling = ESPipelineStageSpelling(_stage.name, _stage.positional, _stage.flags);
    return ESPipelineDiagLine(spelling, isFirst, prior, result, ESPipelineFilterKindReader);
}

+ (NSString *)manPage {
    return
        @"NAME\n"
        @"    man — documentation for archive_pipeline commands and topics\n"
        @"\n"
        @"SYNOPSIS\n"
        @"    man\n"
        @"    man COMMAND\n"
        @"    man TOPIC\n"
        @"\n"
        @"DESCRIPTION\n"
        @"    With no argument, lists all commands and topics with one-line\n"
        @"    synopses. With a command name, returns that filter's full man\n"
        @"    page (synopsis list is generated dynamically from registered\n"
        @"    filters — adding a new filter class makes it appear in the\n"
        @"    index automatically). With a topic name, returns the meta-\n"
        @"    documentation for that topic.\n"
        @"\n"
        @"    Topics document the system as a whole rather than a single\n"
        @"    command. Currently:\n"
        @"\n"
        @"        pipelines    composing archive_cli commands into chains —\n"
        @"                     canonical patterns, retry strategy, common\n"
        @"                     gotchas. Read this if you're new to chaining\n"
        @"                     stages.\n"
        @"        tags         the curated tag layer — kinds, lifecycle, and\n"
        @"                     how to stage intermediate search results as\n"
        @"                     durable subsets via the pipeline write filters.\n"
        @"                     Read this before deciding to tag anything.\n"
        @"\n"
        @"EXAMPLES\n"
        @"    man\n"
        @"    man w2vgrep\n"
        @"    man pipelines\n";
}

@end
