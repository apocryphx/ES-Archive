# Pipeline Unification — one `archive_cli` grammar on every surface

**Status:** Design brief, ready to implement. Nothing implemented yet.
**Audience:** A fresh coding session. Read this whole document first; the code
locations below are exact as of `main` at `bce65b7` (September 8, 2026).
**Archive record:** *Unify the pipeline interface: archive_cli strings on the
HTTP server too (open, September 8, 2026)* — the observation that prompted this.

---

## 1. The problem in one paragraph

The pipeline grammar (`lfind --tag X | w2vgrep "…" | head 5`) is what every man
page, skill file and example teaches, and it is the form Claude uses. But the
grammar is parsed only in the **stdio host** (`ES Archive MCP`). The **HTTP
server** (`ES Archive Server`) exposes `archive_pipeline`, which accepts a
pre-parsed `stages` array and nothing else. So any direct HTTP client — a Codex
or LM Studio session on a persona port, a script, a future `apple-docs` skill
routing concept queries to the AppleDoc persona — has to speak a shape nobody
documents, while the documented shape is unavailable to it. The pipeline is
worth exposing uniformly: over the 68,523-entry AppleDoc persona, a chained
`lfind --tag "Core Data" | w2vgrep "merge changes from another context into
this one" | head 4` returned `mergeChanges(fromContextDidSave:)` at 0.60 in
110 ms.

**Decision (Kolja, September 8, 2026):** make the interface the same on both
surfaces by moving the parser server-side. One parser, one grammar, one set of
man pages that is true everywhere.

## 2. Where things are today

```
stdio (Claude Desktop / Claude Code / LM Studio)
  archive_cli(expression)
      │  Stdio/MCPStdioServer.m        tools/call: intercepts "archive_cli"
      │  Stdio/ESBridgeCLI.m           ESBridgeCLITokenize → ESBridgeCLIParseStages
      │                                ESBridgeCLIExecute → ESBridgeCallTool("archive_pipeline", {stages})
      ▼
  engine.archive_pipeline({stages})
      │  Server/Tools/ESMemoryPipelineTool.m   requires `stages` (array of {name, positional?, flags?})
      ▼  Server/Pipeline/ESPipelineExecutor.m  ESPipelineExecute(stages, ctx, scopeAuthor)
  filters  Server/Pipeline/Filters/*           lfind, w2vgrep, grep, head, tail, sort, wc, cat,
                                               discover, links, arc, revisions, tag, untag, man

HTTP (ES Archive Server, one port per persona)
  archive_pipeline({stages})  ← the only form. No archive_cli tool exists here.
```

Facts that shape the design:

- **The man pages are already server-side.** `man` is a terminal filter
  (`Server/Pipeline/Filters/ESManFilter.m`, 555 lines) and every filter class
  carries its own `manPage`. Nothing about documentation needs to move.
- **The parser is small and self-contained.** `Stdio/ESBridgeCLI.{h,m}`
  (543 lines) holds: a shell-style tokenizer (double quotes with `\"`/`\\`
  escapes, single quotes literal, bare words, `|` outside quotes), a stage
  parser (`--flag value`, boolean flags, positional args), `ESBridgeCLIExecute`
  (wraps the engine call and shapes the response), `ESBridgeCallTool`, and
  `ESBridgeNormalizeRelativeDate`. The header says it plainly: "The CLI is
  composition logic — it has no business in the data engine." This brief
  reverses that stance for the *parser*, because the grammar has become the
  product's documented interface; composition (the filter chain) already lives
  in the engine anyway.
- **The stdio host curates its tool list.** `+[MCPStdioServer memoryCLISchema]`
  is the `archive_cli` schema (description text with the quick examples);
  `toolsListResponseForMessage:` puts it at index 0 and filters out any engine
  tool named `archive_cli` — so the engine can start exposing one without
  changing what Claude sees.
- **Scope is enforced by the executor.** `ESPipelineExecute` seeds the initial
  population from `scopeAuthor` and rejects `lfind --author` that differs. The
  parser move must not touch this.
- **A second bridge-only behavior exists.** `MCPStdioServer` pre-normalizes
  relative dates (`"+30 days"`, `"-2h"`) for `archive_tags`, `archive_store`,
  `archive_update` before dispatch. The `archive_store` tool description even
  promises "the bridge accepts relative offsets". Over HTTP that promise is
  false. Same disease, same cure (§4, phase 2).

## 3. Target

```
any client (stdio, HTTP, script)
  archive_cli({expression})            ← string grammar, documented form
  archive_pipeline({stages})           ← structural form, kept for programs
      │
      ▼  Server/Pipeline/ESPipelineParser.{h,m}   tokenize + parse (moved from ESBridgeCLI)
      ▼  Server/Pipeline/ESPipelineExecutor.m     unchanged
```

- **`Server/Pipeline/ESPipelineParser.{h,m}`** (new): `ESPipelineTokenize`,
  `ESPipelineParseStages` — the tokenizer and stage parser from `ESBridgeCLI`,
  renamed, byte-for-byte the same grammar. Output is the `stages` array shape
  the executor already takes (`{name, positional, flags}`), so no adapter.
- **`Server/Tools/ESMemoryPipelineTool.m`**: accept `expression` (string) *or*
  `stages` (array); exactly one required. With `expression`, parse, then run.
  Parse errors return the bridge's error shape verbatim
  (`{error: "parse_error", message, expression}`), because skills and man pages
  describe that shape.
- **Server-side `archive_cli` tool** (new class or an alias registered in
  `MCPToolDispatcher`): schema = today's `+[MCPStdioServer memoryCLISchema]`,
  moved into the engine; handler = the same path as `archive_pipeline` with
  `expression`. Both apps then list `archive_cli`; the HTTP server gains it,
  the stdio host keeps it at index 0 (its filter already tolerates an engine
  tool of that name — the stdio copy of the schema becomes the engine's).
- **`Stdio/ESBridgeCLI.m`** shrinks to what is genuinely transport-side:
  `ESBridgeCallTool` (if still needed) and, until phase 2, the date
  normalizer. `ESBridgeCLIExecute` and the stdio `archive_cli` interception go
  away; `archive_cli` becomes an ordinary engine tool call.

## 4. Steps

**Phase 1 — parser move (the deliverable).**

1. Create `Server/Pipeline/ESPipelineParser.{h,m}` by moving the tokenizer and
   stage parser out of `Stdio/ESBridgeCLI.m`. Keep the token and stage classes
   (renamed `ESPipelineToken`, `ESPipelineStage`) or return plain dictionaries
   directly — the executor wants dictionaries, so the second is simpler. Port
   the parser's unit tests if any exist under `Testing/`; if none, add a small
   table test for the quoting rules (see §6).
2. `ESMemoryPipelineTool`: accept `expression` or `stages`; update the schema
   (`oneOf` is not needed — describe both, validate in code); route
   `expression` through the parser; keep the `stages` path untouched.
3. Add the engine-side `archive_cli` tool with the schema text from
   `memoryCLISchema` and the same annotations (`readOnlyHint NO`,
   `destructiveHint NO`, since `tag`/`untag` write).
4. `MCPStdioServer`: delete the `archive_cli` interception branch and the
   local schema; let `tools/list` pass the engine's list through, still with
   `archive_cli` first (keep the reordering, drop the local copy). Remove
   `ESBridgeCLIExecute` and the parser code from `ESBridgeCLI.m`.
5. Build both schemes (`ES Archive MCP`, `ES Archive Server`). Run §6.

**Phase 2 — the date normalizer (same shape, smaller).** Move
`ESBridgeNormalizeRelativeDate` into the engine and apply it inside
`archive_tags`, `archive_store`, `archive_update` argument handling, so HTTP
clients get the promised `"+30 days"` behavior. Then `ESBridgeCLI.m` can be
deleted entirely. Do this only after phase 1 is verified; it is independent.

## 5. Constraints — do not break these

- The grammar must not change. Same quoting rules, same flag syntax, same
  boolean-flag behavior, same error messages for unterminated quotes, empty
  stages, dangling pipes. The six `es-archive-*` skills and the seven
  `codex-es-archive*` skills teach this grammar and are not to be edited.
- `archive_cli` must remain first in the stdio `tools/list`.
- Response shapes are part of the interface: `{pipeline, results, count}` on
  success; terminal stages (`cat`, `wc`, `man`) keep their own shapes;
  `{error, message, pipeline}` from the executor; `{error: "parse_error",
  message, expression}` from the parser.
- Persona scope stays with the executor; the parser knows nothing about
  authors. A pipeline arriving on port 59500 sees only AppleDoc, as today.
- `archive_pipeline` with `stages` keeps working unchanged (the stdio host
  currently calls it; scripts may).
- Kolja's in-progress socket-election work touches `Stdio/` — coordinate before
  editing `MCPStdioServer.m`; the interception branch is small and separable.

## 6. Verification

Run after phase 1, before committing.

**Grammar parity (unit level).** Tokenize and parse these on the new parser and
compare with the old `ESBridgeCLI` results (keep the old file around until this
passes):

```
man
lfind --tag 'Isolde' | head 5
lfind --tags "Isolde, ES Archive" | w2vgrep "branching" | head 5
grep Isolde | grep Myth | tag 'Isoldes Stories'
w2vgrep "a phrase with \"escaped\" quotes" --focus week | head 3
discover --mode forgotten | w2vgrep 'continuity' | head 10
lfind --days 7 | sort --by dateModified | tail 3
```

and the error cases: unterminated quote, `lfind |`, `| head 5`, empty string.

**Stdio regression (Claude scope).** From a Claude Code session, run
`archive_cli("w2vgrep \"why the archive is an institution rather than a
memory\" | head 3")`. Expected top hit: *The Institutional Inversion* at about
0.63. Then `archive_cli("man")` and `archive_cli("man lfind")` return the man
text unchanged.

**HTTP parity (AppleDoc persona, port 59500).** The same expression must work
as a string. Expected results and timings from September 8:

```bash
curl -s -X POST http://127.0.0.1:59500/mcp -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,
  "method":"tools/call","params":{"name":"archive_cli","arguments":{"expression":
  "lfind --tag \"Core Data\" | w2vgrep \"merge changes from another context into this one\" | head 4"}}}'
```

| Expression | Expect | Time |
|---|---|---|
| `lfind --tag "Core Data" \| w2vgrep "merge changes from another context into this one" \| head 4` | `NSManagedObjectContext.mergeChanges(fromContextDidSave:)` first, ~0.60 | ~0.1 s |
| `lfind --tag Foundation \| wc` | 10,868 | ~0.06 s |
| `grep NSURLSession \| w2vgrep "resume a download after the app was suspended" \| head 3` | `NSURLSessionDownloadTaskResumeData` first | ~0.5 s |
| `discover --mode hubs \| head 3` | Accelerate API collections | ~0.3 s |
| `lfind --author Claude \| wc` on port 59500 | rejected: scope mismatch | |

The `stages` form of the first pipeline must return the identical result.

**Both apps** build, and the stdio host's `tools/list` still shows
`archive_cli` at index 0 with the same description text.

## 7. Non-goals

- No new pipeline commands, flags, or man-page edits.
- No change to the filters or to `ESPipelineExecute`.
- No change to how personas are bound to ports.
- The AppleDoc-specific routing in the `apple-docs` skill is a separate,
  later task; this brief only makes it possible.
