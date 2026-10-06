# Code health — what holds quality up, what lets it slip, and why not Swift

**Status:** Assessment with a short plan, October 6, 2026. Items 1–3 under
§4 are proposed, not implemented. Item 4 is a standing decision.
**Audience:** Kolja, and any session asked "should this be rewritten" or
"why did nobody notice X was broken". Written after a day of cross-cutting
work (pipeline unification phases 1 and 2, a man page sweep, a test-bundle
repair, a QoS fix in the socket client), so the evidence is fresh and
specific.

---

## 1. The question

Is the code base hindering development or code quality, and would converting
it to Swift help?

Short answer: the code is helping more than hindering. The friction found
today was in the surrounding practice (tests not run, documentation drifting
from behavior), not in the language or the structure, and it is cheap to
close. A Swift overhaul is not recommended; incremental Swift where it fits
is fine.

## 2. What is working

- **The structure explains itself.** One class per tool
  (`Server/Tools/ESMemory*Tool`), one class per pipeline filter
  (`Server/Pipeline/Filters/*`), a protocol (`MCPTooling`) that the
  dispatcher discovers by scanning the Objective-C runtime, and two
  transports that are thin over one engine. A cold reader finds every seam
  for a change in minutes.
- **The design briefs are unusually good.** `pipeline-unification.md` told a
  fresh session where everything was, what must not break, and how to
  verify. Both phases landed on that brief alone.
- **Header comments state intent and constraints**, not just what a method
  does. The socket client's note on why the EOF watcher never closes the fd
  is the kind of sentence that prevents a regression.
- **The code absorbs change.** Two phases of a refactor across the stdio
  host and the engine, a man page sweep, and a concurrency fix touched about
  fifteen files and broke nothing.

## 3. What is actually slowing things down

1. **The test suite was not runnable, and nobody noticed.** The hostless
   bundle (`ES Archive Tests`) had failed to link since the mid-session
   re-election commit (`f0a265b`, September): the unity include that
   compiles the transport sources never picked up `ESLog.m`, so
   `_ESTraceClock` was undefined. No shared scheme existed for the target
   and nothing ran it automatically, so the break was invisible for weeks.
   Fixed in `fbb2003`; a shared scheme now exists. The *pattern* will
   recur without a habit or a hook.
2. **Documentation drifts from behavior.** Found today: four tool
   descriptions promised bridge-side relative-date handling (one of them,
   `archive_timeline` `from`/`to`, was never true on any surface); the `man`
   page named itself documentation for `archive_pipeline`; the brief's own
   example `sort --by dateModified` uses a key that does not exist (the sort
   keys are `recent`, `oldest`, `popular`, `accessed`, `title`). None of
   these are code bugs. Each one misleads the next Claude or the next HTTP
   client. Nothing checks that examples execute.
3. **Untyped dictionaries push type checking to runtime.** Every tool
   re-validates argument types by hand; the helpers in `ESMemoryToolBase`
   exist because a mistyped argument once crashed the server. Manageable,
   but it is the one place Objective-C costs something a typed language
   would not.
4. **Two lists are kept in sync by hand.** `ESPipelineParser` holds a
   hardcoded `booleanOnlyFlags` set (`regex`, `case-sensitive`,
   `attachments`, `body`, `title`, `include-expired`), deliberately decoupled
   from the filters that define those flags. A new boolean flag on a filter
   silently parses wrong (it eats the next positional) until someone
   remembers the list.
5. **A few files are large.** `VectorEngine/ESVectorEngine.m` (~1,460
   lines), `MemoryScope/ESMemoryScopeView.m` (~920),
   `SystemPulse/ESSystemPulseViewController.m` (~900). These are where
   edits get slow and reviews get shallow.

## 4. Plan

**1. Make the suite part of the ship ritual.** One line, now that the
scheme is shared:

```bash
xcodebuild -workspace ES-Archive.xcworkspace -scheme "ES Archive Tests" test
```

Run it before any build-number bump; a pre-push hook or a line in the ship
procedure is enough. Today the suite is 51 tests (UDS transport 14, pipeline
parser 23, date argument 14) and runs in about three seconds.

**2. A self-check test that executes the documentation.** One XCTest that
brings up the engine against an empty in-memory store, calls `tools/list`,
and then (a) runs every example in every filter's `manPage` and the `man`
topics through `ESPipelineParseExpression` + `ESPipelineExecute`, and
(b) runs every `archive_cli(...)` and `archive_tags(...)` example in
`skills/claude/*/SKILL.md`. Assert no `parse_error` and no
`invalid_arguments`; an empty result is fine. This turns documentation drift
from a review problem into a red test. Needs the engine's Core Data stack
to come up hostless — `core-data-context-strategy.md` is the reference;
if that proves heavy, start with (a) parse-only and the filters' flag
validation, which already catches the sort-key class of error.

**3. Let filters declare their boolean flags.** Add an optional
`+ (NSSet<NSString *> *)booleanFlags` to the `ESPipelineFilter` protocol
(`Server/Pipeline/ESPipelineFilter.h`, next to `manPage`). The parser
asks `ESPipelineFilterClassForCommand(name)` for the stage it is parsing
and unions that set with nothing else; the hardcoded list in
`ESPipelineParser.m` goes away. The parser stays ignorant of filter
*semantics*; it only asks a yes/no question per flag name. Keep the parity
table in `ESPipelineParserTests.m` green while doing it.

**4. Leave the language alone.** See §5.

Optional, lower priority: a thin argument-schema validator in
`MCPToolDispatcher` that checks `arguments` against each tool's
`inputSchema` types before dispatch would retire most of the per-tool
type checks in one place. Splitting the three large files is worth doing
only when the next real change lands in them.

## 5. Why not Swift

- **Size and risk.** About 30,000 lines of Objective-C across engine,
  transports, Core Data schema, vector engine and views, plus two
  Objective-C submodules (GCDWebServer, ObjCTokenizer). A faithful port is
  months before parity, during which the shipping product stands still, and
  a rewrite is where regressions come from.
- **The hard parts are not language-shaped.** Socket election, mid-session
  re-election, CloudKit throttling, the fused fetch-request pipeline, the
  embedder integration: these are concurrency, Core Data semantics and
  framework behavior. Swift 6 strict concurrency would make the
  dispatch-heavy transport code *harder* to port, because it leans on GCD
  queues, semaphores and atomics that the Swift model discourages.
- **The tool surface is JSON dictionaries in and out.** Objective-C's
  comfort zone. Swift would mean either untyped dictionaries (no gain) or
  Codable types for 22 tools and 15 filters (a design project of its own).
- **Runtime discovery has no clean Swift equivalent.** `MCPToolDispatcher`
  finds tools by scanning for `MCPTooling` conformers. Swift would replace
  that with a hand-maintained registry.

Where Swift would earn its place, incrementally: new self-contained modules
with a value-typed interior (today's parser and date resolver would have
been fine in Swift); the vector engine if it ever needs more than
Accelerate calls; the views, if they are ever rebuilt (SwiftUI would replace
much of the graph and spiral plumbing); and tests. Mixed-language targets
with a bridging header are routine, so allowing Swift costs nothing and
commits to nothing.

What would change this calculus: a feature that fights the language, a
framework deprecation that forces the transport or persistence layer to be
rewritten anyway, or a collaborator who will not touch Objective-C. None of
those is the case today.

## 6. Verification for the plan

- Item 1: a build-number bump commit is preceded in history by a green
  test run (or the hook refuses the push).
- Item 2: deliberately break one man example (e.g. change a sort key) and
  the self-check goes red; restore it and it goes green.
- Item 3: add a throwaway boolean flag to one filter, write
  `grep --newflag "pattern"`, and the parser yields `positional: ["pattern"]`
  without any edit to `ESPipelineParser.m`; the 23-case parity table still
  passes.
