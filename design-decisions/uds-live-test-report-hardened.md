# UDS Shared Engine — Hardened-Build Live Test Report

**Date:** 2026-07-08
**Branch under test:** `feature/uds-server` (`099c8ec` — the transport-hardening commit
adapted from the UDS-Shared-Engine template; see
[`uds-adaptation-from-template.md`](uds-adaptation-from-template.md)).
**Build:** a **signed, Release, direct-distribution** export of the `ES Memory MCP`
stdio target (team `2PYWYF3C55`), carrying the real `group.com.elarity.esmemory`
App Group and CloudKit entitlements — i.e. the actual App Group container and the
production CloudKit-synced Core Data store, not a fixture.
**Method:** two held-open stdio sessions driven with piped JSON-RPC (the shape
Claude Desktop/Code produce), one electing as host, one relaying under
`--author UDS-Hardening-Test`. Driver: a throwaway Python harness; the durable
automated coverage lives in `Testing/uds-transport/` and the `ES Memory Tests`
XCTest target.
**Safety:** three archive backups confirmed beforehand by Kolja; every write ran
under the isolated synthetic persona `UDS-Hardening-Test` and was erased and
verified gone. The production Claude-Desktop MCP servers (pre-UDS build) ran
untouched throughout.

## Why this report exists

The prior report ([`uds-live-test-report.md`](uds-live-test-report.md)) validated
the *first* UDS transport. This branch then rebuilt that transport from the
hardened template — three-role concurrency, a client timeout, cooperative
shedding, a single shared path resolver, robust writes. The unit suites exercise
all of it against a **stub** handler; what remained unproven was the same
hardened transport against the **real Core Data + embedder** on a **signed**
build (the only build in which the App Group container — and therefore the socket
— resolves at all). This is that empirical record.

## 1. Topology — one engine, two sessions (the N×RAM fix, measured)

With no host running, session A elected and bound the real socket; session B
connected and relayed. Because `ESLog` is compiled out of a Release build, the
`local engine NOT loaded` line is invisible — so the proof is **resident memory**,
which is stronger:

| | Host (session A) | Relay (session B) |
|---|---|---|
| Role | bound the socket, loaded Core Data + the CoreML embedder | relayed every request |
| RSS | **577 MB** (434 MB on a second run) | **31 MB** |
| tools/list | 22 tools, served in-process | 22 tools, served over the socket |

A ~19× memory gap. The relay ran the entire 22-tool MCP surface — including a
full write/read/update/grep cycle — while never loading Core Data or the ~500 MB
embedder. That is exactly the property the socket exists to buy: N Claude
sessions, one engine.

## 2. Persona scoping + isolation across the relay

The load-bearing safety proof, taken from the stored record rather than logs:

* A `memory_store` issued by the relay **with the `author` argument omitted**
  landed with **`"author": "UDS-Hardening-Test"`** — the connection's handshake
  persona (confirmed by reading the record back). The write stamp follows the
  socket connection, not the host's own identity.
* From the **host** session (default persona), `memory_read` of that title
  returned `not_found`, and `memory_grep` of its unique token returned
  `match_count: 0, scanned_memories: 0`. One engine, one store, and the host
  session still could not see the relay persona's private memory — read scope is
  enforced per-connection-persona through the relay.

## 3. Full CRUD over the relay

`memory_store → memory_read → memory_grep → memory_update (append) → memory_grep
→ memory_erase → read-after-erase`, all through the relaying session: **all
correct.** Lexical grep was read-your-writes (immediate hit on the unique token,
same connection); the appended line was visible to the next grep. Erase returned
`erased`; the follow-up read returned `not_found` and grep returned zero — the
test memory was gone, the archive left clean.

## 4. Lifecycle — clean shutdown unlinks the socket

`socket present: False → True (after host start) → False (after SIGTERM)`. The
clean-exit unlink — the defect the prior report caught being fixed, now on the
hardened `-flushAndSave → -stop` path — held on the signed build: no stale socket
left behind, so the next session elects against a clean path rather than leaning
on stale-socket recovery.

## 5. Consistency model (measured, unchanged by the relay)

| Read path | Visibility of the just-stored memory |
|---|---|
| `memory_grep` (lexical, Core Data direct) | **immediate** — read-your-writes on the unique token |
| `memory_search` (semantic) | **empty within the test window** — `"No memories in your scope yet"` |

The semantic miss is the documented async vector-index lag, sharpened here by a
**brand-new persona**: `UDS-Hardening-Test` had zero vectors at `warmCache` time,
and the first memory's vector had not been encoded into its scope before the
search ran (the query short-circuits when the scope's vector set is empty). This
is engine behaviour identical with or without the relay — the query relayed and
answered correctly; only indexing lagged. Not re-probed for the eventual hit
because the memory was erased immediately after (the prior report already pins the
warm-embedder hit at ~250 ms).

## 6. Findings outside the transport

1. **Model packaging.** The *first* signed export shipped **without** the embedder
   — `EmbeddingGemmaEncoder.mlmodelc` and `embeddinggemma.tokenizer.json` are
   gitignored ([`.gitignore`](../.gitignore) lines 15–16), so a clean clone or CI
   build produces a non-functional engine that fails silently: semantic search
   returns empty and host RSS sits at ~64 MB instead of ~500 MB. A build-phase
   presence check, or a documented model-provisioning step, is warranted before
   cutting a release or wiring CI. The re-export with the model bundled behaved
   correctly.
2. **Client timeout not stress-tested live.** No operation was slow enough to
   approach the 120 s budget (the cold search short-circuited on the empty scope
   rather than doing a slow encode), so the timeout's live behaviour rests on the
   unit proof (a genuinely slow op returns a clean `-32000`, never a hang) plus a
   deliberately generous default.
3. **Release strips `ESLog`.** Topology diagnostics are Debug-only; RSS was the
   behavioural substitute. If a future live test wants the logs, drive a Debug
   signed build, or read `ESLogAlways` via `log stream --predicate 'subsystem ==
   "com.elarity.es-memory-mcp"'`.

## Verdict

The hardened UDS shared engine is **fit for real use** on the evidence of this
run: election and clean unlink on the real socket, a measured one-engine topology,
full CRUD and persona isolation proven from stored data across the relay, and a
clean archive afterward. No transport defect surfaced. The only imperfect result —
semantic search missing a just-created persona's first memory — is the known
indexing-lag consistency model, not a relay fault. The one actionable defect is
build packaging (the un-bundled model), which is orthogonal to this branch.

## Open items (carried, not blockers)

1. Model provisioning for clean/CI builds (finding 1) — the one thing to fix
   before release.
2. Live confirmation of the semantic hit after the async hop, and of the 120 s
   timeout under a genuinely slow relayed op — both proven at the unit level,
   neither exercised live here.
3. Mid-session re-election on host EOF — still future work; the client now fails
   a dropped relay cleanly (`-32000`) instead of hanging, which is the surface it
   would build on.
4. A possibly-orphaned vector from the erase in the synthetic scope — negligible;
   `memory_maintenance` reindex clears it.
