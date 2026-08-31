# UDS Shared Engine — First Live-Data Test Report

**Date:** 2026-07-07
**Branch under test:** `feature/uds-server` (`041fc73` → `5dc93dd` during testing)
**Tester:** Claude (Opus 4.8 / Fable 5), driving the stdio binary directly with
piped JSON-RPC — the first exercise of the UDS transport against the **real
production archive** (CloudKit-synced Core Data store), not a scratch fixture.
**Safety:** full archive backup taken beforehand by Kolja; all writes and
destructive operations ran under an isolated synthetic persona
(`UDS-Spike-Test`); every test memory was erased and verified gone. The
production ES Memory Server (old build, no UDS code) ran untouched throughout.

## What was tested

The UDS transport stack introduced on this branch: `MCPUnixSocketServer`
(bind-election host), `MCPSocketClient` (relay client + persona handshake), and
the `ESEngine` policy (connect → relay, else host). See
`socket-election.md` for the mechanism; this report is the empirical record.

## 1. Concurrency — two live sessions, one engine

Two stdio processes with held-open stdin pipes (the shape Claude Desktop/Code
actually produce), alive simultaneously:

| | Session A (`--author Claude`) | Session B (`--author Isolde`) |
|---|---|---|
| Role | host — loaded engine, bound socket | relay — `local engine NOT loaded` |
| Interleaved `tools/list` ×2 each | 22 tools, served in-process | 22 tools, served over the socket |
| Engines loaded (`dispatch map` log count) | 1 | 0 |

A third session joined mid-test and relayed to the live host — three
concurrent sessions, one engine. Interleaved requests (B, A, B, A) all
answered correctly with both sessions live.

## 2. Lifecycle

* Client session exits (SIGTERM) → host unaffected, keeps serving. ✓
* Host exits → next fresh session detects the socket state, brings up its own
  engine, and re-elects as host. ✓
* **Bug found and fixed (`5dc93dd`):** a host exiting via SIGTERM/EOF left its
  socket file behind — the stdio drain path never called
  `MCPUnixSocketServer -stop`. The stale-socket recovery (probe →
  `ECONNREFUSED` → unlink → re-bind) absorbed it exactly as designed, which is
  why the test still passed functionally — but clean exits shouldn't lean on
  crash recovery. `ESEngine -flushAndSave` (already on both shutdown paths)
  now stops the listener first. Re-verified: SIGTERM → `[MCP-UDS] stopped`,
  socket removed.

## 3. Personas across the relay

The write-path proof, from the stored record itself rather than logs: a
`memory_store` issued by the relaying session (`--author UDS-Spike-Test`)
through a host running as default "Claude" landed with
**`"author": "UDS-Spike-Test"`** — the connection's handshake persona, not the
host's. Isolation held in every direction tested:

* Host-scope semantic search for the test memory's content: not returned
  (host got only its own scope's results).
* Host-scope `memory_read` by exact title, without author: `not_found`.
* Host-scope `memory_read` with explicit `author: UDS-Spike-Test`:
  `not_found` — cross-persona read refused even when named (consistent with
  the owner/author share model).
* The store-time similarity flare is also scope-restricted in code
  (`scopedVectorIDs` in `ESMemoryStoreTool`), so a store response cannot leak
  another persona's summaries. Not separately exercised, noted from source.

## 4. Full CRUD over the relay

`memory_store` → `memory_read` → `memory_update` (append) → `memory_grep` →
`memory_search` → `memory_erase` → read-after-erase, all via the relaying
session: **all correct.** The pipeline surface (`memory_cli`) also transits
the relay by construction — the host-local CLI executor funnels through the
same `ESEngine.handleRequest:` that relays.

One tester error worth recording as client guidance: `memory_store`'s
`summary` is not the title — **title = first line of `body`** (documented in
the tool description; also: edits go through `memory_update`, never
erase + re-store, which destroys `dateCreated`). The first test run's
`not_found` cascade was entirely this, not a transport fault.

## 5. Consistency model (measured)

Store, then poll. Lexical vs semantic visibility of a just-stored memory:

| Read path | Visibility after `store` returns |
|---|---|
| `memory_grep` (lexical, Core Data direct) | **0 ms — read-your-writes.** Immediate hit on a unique token, same connection. |
| `memory_search` (semantic), warm embedder | **~250 ms.** Three trials: miss at +0.0s, hit at +0.25/0.25/0.26s, full score immediately (0.814–0.816), no ramp. |
| `memory_search`, cold embedder (first semantic op of the process) | seconds — the async vector hop absorbs the one-time model load. |
| Duplicate detection | 0 ms — the similarity flare in the store *response* is computed synchronously. |

Interpretation: the vector lands one fast async hop after the store
transaction. The earlier "search misses for seconds after store" observations
were cold-start artifacts, not an indexing lag. Practical consequence: any
real workflow sees its own writes; only a store-then-search inside a quarter
second (warm) can miss. The shared-host topology improves the cold case too —
the host's embedder is warm for every relaying session after the first.

## Verdict

The UDS shared-engine transport is **fit for real use** on the evidence of
this test: correct under concurrency, self-healing across host lifecycle,
persona-safe on the write path (proven from stored data), full CRUD + pipeline
parity with in-process operation, and a consistency model that is
read-your-writes for lexical and ~250 ms for semantic. One defect was found
(stale socket on clean host exit) and fixed during the test; no unexplained
behavior remains.

## Open items (carried, not blockers)

1. Default author flip to "anonymous" — deferred by decision until after
   testing (currently `ESDefaultAuthor` = "Claude").
2. Mid-session re-election: a relaying session whose host exits does not
   currently reconnect; its requests fail until the session restarts.
   Acceptable for short-lived Claude sessions; straightforward future work in
   `MCPSocketClient` (EOF → reconnect → re-run election).
3. Branch consolidation: `feature/uds-server` is based on `500e728` (the last
   pre-experiment commit that builds); it needs a rebase onto the live line
   before merging.
4. Socket trust boundary: any same-user, same-App-Group process may connect;
   accepted for now (see `socket-election.md`, failure modes).
