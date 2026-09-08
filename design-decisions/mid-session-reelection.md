# Mid-session re-election: a relay outlives its host

Status: shipped (2026-09-04).
Code: `ES_Archive/Stdio/ESEngine.m` (`-reelectReplacing:`, the retry loop in
`-handleRequest:`), `ES_Archive/Stdio/MCPSocketClient.m` (typed error codes,
`-isConnected`, lock-owned `-close`), `ES_Archive/Stdio/MCPStdioServer.m`
(`-finishShutdown`, the linger), `ES_Archive/Server/MCPUnixSocketServer.m`
(`connectionCount`, the idle notification), `ES_Archive/Stdio/ESStdioAppDelegate.m`
(`-activateHostRoleAtLaunch:`).
Predecessors: `socket-election.md`, `uds-adaptation-from-template.md` — both
listed this as future work.

## The failure it fixes

Every Claude session spawns its own ES Archive MCP process. The election
(`socket-election.md`) makes exactly one of them host the engine; the rest relay
to it over the socket. Until this change a relay *terminated* when its host
closed the connection: it had nothing to serve and, the reasoning went, Claude
sessions are short-lived, so the next session re-elects.

That reasoning held for Claude Code. It does not hold for Claude Desktop, which
spawns the server **twice** at startup — a probe instance it shuts down within a
second, then the real one, plus a shared-pool instance for Cowork and Code
sessions. The probe spawns first, so it usually wins the bind. Its stdin EOF
stopped the socket, every relay saw EOF and terminated, and Desktop logged
`Couldn't start for Cowork and Code sessions. Error: shared engine connection is
closed`. Over ~a week of `mcp-server-ES Archive.log`: 41 Claude-spawned hosts,
35 relays killed by host loss, 12 shared-pool failures. The same mechanism was
visible in the pre-rename ES Memory log (17 kills); Desktop's double spawn just
made it fire on every launch.

A second trigger was the user quitting the Claude-spawned host from its own Dock
icon (host ⟺ GUI in Full mode): same cascade.

## Two changes

### 1. Re-election in the relay (`ESEngine`)

When the relay's `MCPSocketClient` reports EOF (idle watcher or mid-request), or a
request finds the connection dead, `ESEngine` re-runs the election it ran at
launch: connect to whichever host now owns the socket, else bind and load the
engine itself (`-electAndConnect` is the same code path as `-start`; the engine
loads at most once, `MCPUnixSocketServer` re-binds cleanly after a `-stop`).

Concurrency: a single `NSCondition` gate. The first thread to notice runs the
re-election; every other stdio request parks on the gate and, once it opens,
serves from the new role. The election itself runs on the main thread (Core Data
is main-bound, and that is where `-start` ran), so the *waiter* must never be
main — the disconnect notification hops to a utility queue first. Closing the dead
client also happens off-main, because `-close` waits for any request still on the
wire, which for a wedged (not dead) host can be the full client timeout.

Retry policy for the request that hit the failure — decided by the error code
`MCPSocketClient` returns:

| code | meaning | retried on the new host? |
|---|---|---|
| `-32001 ConnectionLost` | never sent (connection already closed, or the write failed) | yes, once |
| `-32000 Timeout` | host may still be executing it | no — a second store would duplicate |
| `-32002 ReplyLost` | host closed after the request was sent, outcome unknown | no — Claude retries deliberately |

If the relay comes out of re-election as the host, `ESEngine` posts
`ESEngineDidBecomeHostNotification` and the delegate runs the host block it would
have run at launch (menu or status item, activation policy, tag janitor, vector
backfill) — but without onboarding or `activate`, because the user is in the
middle of something.

### 2. A host lingers for its peers (`MCPStdioServer`)

When a host's own stdio session ends (EOF or SIGTERM) while peers are still
connected, stopping would force every peer through re-election and one of them
through a cold engine load. So `-finishShutdown` checks
`MCPUnixSocketServer.connectionCount`: if peers remain, the process saves Core
Data, keeps serving, and exits on `MCPUnixSocketServerDidBecomeIdleNotification`
after a 2 s grace period (a re-electing peer can drop and come straight back).
A later SIGTERM while lingering is honored only if no peer remains.

This is what turns Claude Desktop's probe instance from a hazard into the
long-lived host: it wins the bind, its stdin closes, and it simply keeps the
engine up for the sessions that follow. Host ⟺ GUI still holds — the lingering
host is the one with the Dock icon, exactly like a hand-launched host today.

Change 1 alone would be correct; change 2 removes the churn. Change 2 alone would
not be enough: if the wrapper Claude Desktop spawns us through follows EOF with
SIGKILL, only re-election saves the peers.

## Invariants kept

- **Single writer.** Only the process holding the bind loads Core Data. A relay
  that re-elects loads the engine only after it has bound the socket.
- **One closer.** `MCPSocketClient` closes its fd in exactly one place, under its
  lock, after the EOF watcher's cancel handler has run. The watcher itself never
  closes. Before this change the watcher closed the fd from its own handler,
  which could close it under a request mid-`poll()` and — now that re-election
  opens a new socket immediately afterwards — let the freed number be reused by
  the new connection while a stale reader still held it.
- **A timed-out request is never retried.** Same rule as
  `uds-adaptation-from-template.md`; the connection is still severed on timeout,
  but the *process* now recovers by re-electing instead of staying dead.

## Verified

`Testing/uds-transport/run.sh` (the Foundation-only harness) adds
`test_host_loss`: a client connected to a live host observes the host's `-stop`
as `MCPSocketClientHostDisconnectedNotification`, reports `isConnected == NO`,
returns `-32001` for a subsequent request, survives `-close`, and a fresh client
connects to a re-bound host on the same path. Plus the host's idle notification
after its last peer leaves.

`Testing/stdio-reelection/run.sh` drives the real (unsigned Debug) binary through
the whole scenario over stdio pipes on a private socket: A hosts, B and C relay,
A is SIGKILLed, B and C re-elect (one hosts and raises the host role, the other
relays to it), the new host's stdin closes and it lingers for its peer, the peer
leaves and the host exits with the socket unlinked. 21 checks; both relays were
serving again 0.9 s after the kill.
