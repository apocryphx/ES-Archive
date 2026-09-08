# Adapting the UDS transport from the hardened template

Status: shipped on `feature/uds-server` (2026-07-08).
Code: `ES_Archive/Server/ESEngineSocket.{h,m}`, `ES_Archive/Server/MCPUnixSocketServer.m`,
`ES_Archive/Stdio/MCPSocketClient.m`, the two `main.m`s, and the two host blocks
(`ES_Archive/Stdio/ESEngine.m`, `ES_Archive/AppDelegate.m`).
Template: the sibling repo `UDS-Shared-Engine/` — a minimal, load-tested
extraction of exactly this pattern (one process owns an expensive engine; others
relay over a UNIX-domain socket), with an XCTest suite and a `udsload` fuzz/stress
harness. Tests: `Testing/uds-transport/run.sh`.

## Why this exists

The UDS layer shipped earlier on this branch (`socket-election.md`,
`uds-live-test-report.md`) was correct on the hard part — the election — but thin
on transport robustness. The `UDS-Shared-Engine` template was then built to
stress the *same* pattern under real load in isolation, and it surfaced a
catalogue of failure modes ES Memory's version shared. This pass folds the
template's hardening back in. The relationship is deliberate and worth
remembering: **the template is the reference implementation of ES Memory's own
transport** — when the transport needs work, look there first.

## The boundary question, settled

Before this work there was an open question: should the socket relay at the
per-tool `executeWithArguments:persistentStore:scope:error:` call instead of at
the JSON-RPC envelope? No. `persistentStore` is a live, non-serializable Core
Data object graph — the call can only run where the store lives (the host), so
the socket must sit above it. The template independently draws its line at the
same altitude (`KVEngine handleRequest:` → reply dictionary, engine-agnostic,
behind a handler block), which is exactly `MCPUnixRequestHandler` /
`ESEngine.handleRequest:scope:`. Two independent arrivals at the request-
dictionary boundary; keep it there.

## What was adopted

1. **One socket-path resolver, shared by both ends** (`ESEngineSocket`). The host
   and client used to resolve the path with *different* fallbacks — the host fell
   back to `$HOME`, the client returned nil — so a misconfigured App Group made
   the host advertise on a path no client read, silently breaking sharing. Now a
   single `ESEngineSocketPath()` (with a `UDS_SOCKET_PATH` test override and a
   `sun_path` overflow → chdir fallback) is the only resolver. Host and client
   can no longer disagree — the invariant `socket-election.md` §1 always assumed.

2. **Three-role concurrency** (`MCPUnixSocketServer`). The old single serial
   `_ioQ` ran accept + every connection's I/O + dispatch, and each request blocked
   it on `dispatch_sync(main)` — so a slow engine call (a cold embedder is
   seconds) blocked new `accept()`s and every other peer. Now: a serial **accept**
   queue (drains a burst, non-blocking listen, `SOMAXCONN`), a concurrent
   **connection** queue (one non-blocking read source per fd), and the **engine**
   on the main queue as before. This does not add engine throughput — the store is
   still main-bound and single-writer — but accepts and other peers' reads stop
   being held hostage by one in-flight request. It is what makes "N concurrent
   sessions, one engine" actually concurrent.

3. **`writeAll:` on both ends.** Replies used a single `write()` that could
   truncate a large frame (search results, tool schemas) on a short write. Now a
   short-write / `EINTR` / `EAGAIN`→`poll(POLLOUT)` loop.

4. **Connection-source hygiene.** `_connSources` was an `NSMutableArray` that a
   closing connection never pruned — a slow leak on the long-lived Server host.
   Now an `NSMutableSet` whose cancel handler removes its own source.

5. **`SIGPIPE` + `RLIMIT_NOFILE`** raised in both `main`s (the stdio main already
   ignored SIGPIPE; `MCPUnixSocketServer` also ignores it in `-init` and sets
   `SO_NOSIGPIPE` per connection). A connection burst can otherwise exhaust the
   default 256 fds, after which `accept()` silently stops.

6. **Cooperative shedding.** `MCPUnixRequestHandler` gained an `isClientConnected`
   predicate (`recv(MSG_PEEK|MSG_DONTWAIT)`); both host blocks check it and shed a
   request whose client has already gone, before spending the engine.

7. **A runnable test harness** (`Testing/uds-transport/`). The template's
   misbehaving-client catalogue, adapted to ES Memory's framing + persona
   handshake + shedding, as a clang-built standalone (no Core Data / AppKit, stub
   handler, `UDS_SOCKET_PATH` on a `/tmp` socket). It would have caught the
   stale-socket-on-clean-exit bug that was found by hand.

## What was deliberately NOT adopted

- **The template's election.** `UDSServer` does `fileExists` → connect-probe →
  `unlink` → `bind` — a check-then-act with a TOCTOU window between the probe and
  the bind. ES Memory binds *first* and treats `EADDRINUSE` as the election
  signal (the check **is** the act). ES Memory's election is the stronger one;
  `socket-election.md` §1 forbids exactly the template's shape. Kept verbatim —
  the concurrency rework was written around it, and the harness re-verifies
  defer-to-live-peer and re-bind-after-stop.

- **The template's timeout-severs-the-connection behavior.** The template is
  connection-per-request, so severing costs one request. ES Memory is
  connection-per-**session** (one held-open connection, many requests, the persona
  handshake). So the client timeout is (a) **generous** — default 120s,
  `UDS_CLIENT_TIMEOUT`-overridable — so a legitimately slow reply never trips it,
  and (b) on a trip it returns a clean JSON-RPC **error envelope** for that id
  (code `-32000`) instead of nil, and marks the connection dead so a late reply
  can never desync the stream. This is the real fix for the old hang: a dropped
  relay used to return nil, indistinguishable from a notification, so the stdio
  writer sent nothing and the caller hung on that id forever.

## ES-Memory-specific semantics to remember

- **Shedding fires on session death, not per-request abandonment.** ES Memory's
  connection is long-lived, so the practical trigger for `isClientConnected → NO`
  is the whole connection closing (the Claude session ended). A `memory_store`
  from a departed session is therefore dropped and **not** persisted — deliberate:
  do not mutate the archive for a session that no longer exists to see the result.

- **Mid-session re-election — shipped 2026-09-04** (`mid-session-reelection.md`).
  On EOF or a timeout the relaying client still marks its connection dead, but
  `ESEngine` now re-runs the election and serves from the new role; the request
  that hit the failure is retried only when its error code says it never reached
  the old host (`-32001`), never on a timeout (`-32000`) or a lost reply
  (`-32002`).

## Invariant added

**The path is resolved in exactly one place.** Any code that needs the engine
socket path calls `ESEngineSocketPath()` — never re-derives the App Group
container or the leaf name. Host and client agreeing on the rendezvous is not a
coincidence to maintain by hand; it is a single function.
