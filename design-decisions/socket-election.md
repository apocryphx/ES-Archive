# Socket Election: how ES Memory picks one engine per user

Status: shipped on `feature/uds-server` (2026-07-07).
Code: `ES_Archive/Server/MCPUnixSocketServer.m` (election + serve),
`ES_Archive/Stdio/MCPSocketClient.m` (client side),
`ES_Archive/Stdio/ESEngine.m -start` (the policy that uses both).
Reference implementation with a minimal shared-counter proof:
`XPC Demo App/XPC Demo App/LocalServer/` in the sibling demo repo.

## The problem

N concurrent Claude sessions each spawn their own ES Memory MCP process. Without
coordination, each loads its own engine — its own Core Data stack and its own
copy of the embedder — which is the N×RAM problem. We want **exactly one engine
per user session**, with every other process connecting to it as a client.

macOS has two native mechanisms for a cross-process singleton, and both are
closed to a Mac App Store app (see `REDESIGN.md` §8b–8d on `dual-mode-ui`):
launchd agents are killed by MAS launch constraints, and `ServiceType=User`
bundled XPC services are refused by launchd. So we run the election ourselves.

## The core idea: let the kernel be the returning officer

The election is **`bind(2)`-exclusivity on a UNIX-domain socket** at a
well-known path (the App Group container, so both bundles resolve the same
file):

```
~/Library/Group Containers/group.com.elarity.esmemory/es-memory-engine.sock
```

`bind()` on a UDS path is **atomic and exclusive**: the kernel allows exactly
one process to bind a given path. There is no lock file to take, no PID file to
trust, and — critically — no *check-then-act* window. A naive design
("does the socket exist? no → I'll be the server") has a race between the check
and the act; two processes can both pass the check. With bind-as-election the
check **is** the act. Two processes can both call `bind()` at the same instant
and the kernel guarantees exactly one `0` and one `EADDRINUSE`.

That single syscall outcome assigns the role:

* `bind() == 0` → **this process is the host.** `listen()`, start accepting,
  serve the engine.
* `bind() == EADDRINUSE` → someone holds the path. But *who* — a live host, or
  the corpse of a crashed one? That's the next section.

## Live peer vs. stale socket: the connect-probe

A UDS socket file is not removed when its owner dies; the path stays on disk,
still yielding `EADDRINUSE`, with nobody accepting. So on `EADDRINUSE` we
probe:

```
connect(probe_fd, path)
  ├─ succeeds        → a LIVE host is accepting. We are a client. Done.
  └─ ECONNREFUSED    → stale socket (owner is gone). unlink(path), retry bind.
```

`connect()` on a UDS only succeeds if a process is actually blocked in
`accept()` on that path — it cannot succeed against a corpse. That makes the
probe a reliable liveness test with no timeouts, no PID checks, no heartbeats.

The full loop, as implemented (`-startWithRequestHandler:error:`):

```
for attempt in 1...4:
    fd = socket(AF_UNIX, SOCK_STREAM)
    if bind(fd, path) == 0:
        listen(fd, 32); become HOST; return
    if errno == EADDRINUSE:
        if connect-probe succeeds:  defer to live peer; return  (caller connects)
        unlink(path)                # stale corpse — clear it
        continue                    # retry bind
    else: hard error; return
```

The loop is bounded (4 attempts) because each retry only recurs if *another*
process bound the path in the instant after our unlink — i.e., we lost a
fresh election, and the next iteration's probe will find that live winner and
defer. Convergence is one or two iterations in practice; the bound is a
backstop, not a tuning knob.

## The policy layer: who tries to host, and when

The election mechanism is policy-free; `ESEngine.start` supplies the policy:

```
1. CONNECT FIRST.  MCPSocketClient connect → a host exists?
      yes → relay every request to it. Do NOT load a local engine. Done.
2. ELECT BEFORE LOADING.  No host answered → try to BIND the socket
   (-electAsHostWithError:) BEFORE loading anything.
      lost (a peer bound first) → connect and relay, WITHOUT ever loading the
             engine. This session stays relay-weight (~30 MB).
      won  → we hold the socket; fall through to load.
3. LOAD, THEN SERVE.  Only the bind winner loads the engine (Core Data,
   migrations, dedup, vector cache) and then begins accepting
   (-serveWithRequestHandler:). Peers that connected while it loaded waited in
   the listen backlog and are served the instant it starts accepting.
```

Ordering matters, and step 2 is the load-bearing part: binding *before* loading
is what makes one-engine-per-user hold even on a **simultaneous** cold start.
Every racer that loses the bind relays without ever touching Core Data or the
embedder — so N sessions started at the same instant converge to one ~500 MB
engine plus (N−1) ~30 MB relays, not N engines. (The original design loaded the
engine *first* and had the loser keep it as a "harmless local fallback"; live
testing on the TestFlight beta measured that fallback at ~475 MB per lost-race
session — correct but wasteful, which is why the load now follows the bind.
Only the winner also runs the deduplicator, so exactly one writer sweeps.)

The one cost: a peer that connects during the host's cold-start load waits in
the backlog until the host finishes loading (a few seconds) rather than getting
an immediate answer. That window is bounded and only occurs at cold start, and
it is strictly cheaper than the alternative of the peer loading its own engine.

The **ES Memory Server** menu-bar app runs the same election at launch (with
`MCPServer`'s dispatch as the handler). Because it's long-lived and usually
already running, it wins step 1 of every stdio session's election — making it
the *de facto* preferred host without any explicit priority mechanism. Priority
falls out of lifetime.

## Per-connection identity: the persona handshake

One socket serves many clients with different personas. Immediately after
`connect()`, a client writes a single handshake line:

```json
{"jsonrpc":"2.0","method":"$/esmemory/author","params":{"author":"Isolde"}}
```

Stream sockets deliver bytes in order, so the handshake is guaranteed to be
processed before any request on that connection. The host stores the author
**per connection** and dispatches every subsequent request on that connection
under `scopeWithAuthor:` of *that* author — never the host's own. A host
running as "Claude" serving a peer running `--author Isolde` writes Isolde's
memories under Isolde. The handshake is transport-level (never forwarded to the
engine); no author line means the connection scopes to the default author.

## Failure modes, honestly

**Host exits cleanly (session ends).** Its socket is unlinked in `-stop`;
surviving peers see EOF on their connection. Currently a relaying session does
not re-elect mid-session — its requests fail until it restarts (Claude sessions
are short-lived, so in practice the next session re-elects). Mid-session
re-election on EOF is a straightforward future addition to
`MCPSocketClient` (reconnect → re-run `ESEngine` election).

**Host crashes.** The socket file remains as a corpse. The next process to
start probes it, gets `ECONNREFUSED`, unlinks, and re-elects. Recovery is
automatic and requires no janitor process.

**The split-brain window (the one real race).** Two processes, A and B, both
observe the same *stale* socket, both get `ECONNREFUSED`, and both decide to
unlink. If the interleaving is: A unlinks → A binds (fresh socket on the path)
→ **B unlinks (removing A's fresh socket!)** → B binds — then A and B are
*both* listening: A on an unlinked inode (its existing clients keep working;
no new client can reach it), B on the path (all new clients go to B). That is
a temporary two-host split. Why we accept it rather than adding a lock file
(which would reintroduce the crashed-holder problem the election exists to
avoid):

1. The window requires two processes to race through probe→unlink within
   microseconds of each other *against an already-crashed host* — a crash
   followed by a near-simultaneous double start.
2. The consequence is bounded: A serves only its pre-split clients until they
   disconnect, then idles; B serves everyone new. No requests are lost.
3. The store itself tolerates it: both hosts open the same Core Data store
   with persistent history tracking + remote-change notifications — the same
   multi-instance configuration ES Memory shipped with before any of this
   work, when every session hosted its own engine. Split-brain briefly
   degrades to the previous status quo, not to corruption.

**Unlink of a live socket by an outside actor.** Anything with group-container
file access could unlink the socket while the host lives — producing the same
bounded split as above on the next election. The socket is reachable only
by same-App-Group, same-user processes; within that trust boundary this is
accepted.

## Why not the alternatives

| mechanism | verdict |
| --- | --- |
| launchd LaunchAgent (`SMAppService`) | true singleton, durable host — but killed by MAS launch constraints (`REDESIGN.md` §8b); Developer-ID only |
| bundled `.xpc`, `ServiceType=User` | refused by launchd for app-embedded services ("Path not allowed in target domain", §8c) |
| bundled `.xpc`, `ServiceType=Application` | launches, but one instance **per client** — the N×RAM problem restated |
| lock/PID file | check-then-act races; crashed holder leaves a lie on disk that needs timeout heuristics to clear |
| localhost TCP port | works (it's the HTTP server's mechanism) — but consumes a port, needs port config, and the port number must be communicated; the UDS path is a fixed rendezvous with filesystem permissions |
| **UDS bind-election** | kernel-arbitrated, MAS-safe, no daemons, self-healing after crashes; costs: host lifetime = process lifetime, and the bounded split-brain window above |

## Invariants for future changes

1. **Never separate the probe from the decision.** Any "is a host running?"
   check that isn't `bind()` or `connect()` on the socket itself reintroduces
   check-then-act.
2. **The handshake must remain first-write-after-connect** on the client, and
   must never be forwarded to the engine by the host.
3. **The handler owns scoping.** The election layer (`MCPUnixSocketServer`)
   knows nothing about personas beyond passing the connection's author string
   through; keep it engine-agnostic (it is shared by the Server app and the
   stdio host with different handlers).
4. **A host that loses its socket must not fight for it back.** If re-binding
   logic is ever added, it must go through the same election (probe first) —
   never a blind unlink of a path someone else may own.
