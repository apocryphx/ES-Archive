# Multi-Persona ES Archive — Implementation Brief

**Status:** Design complete, ready to build. Nothing implemented yet.
**Audience:** A fresh Claude Code session that will execute this.
**Authored:** June 2026, by the Claude instance that designed it with Kolja, as a clean handoff — the design conversation happened at the end of a long session, and focused implementation deserves a clean aperture.

---

## 0. Orient first

1. Read this whole document.
2. Pull the full design record from the archive for the *why* behind every call: via the `es-archive` MCP, `archive_search "multi-persona port author table"` → the decision memory **"Multi-persona ES Memory: port→author table, not CloudKit zones (June 2026)"**. It contains the complete dialogue-derived rationale, including corrections. This brief is the executable summary; that memory is the source of truth.
3. **This is Kolja's daily-driver production system.** Work on a branch (`feature/multi-persona-ports`), build and test, and do **not** commit until he has reviewed. Pause at the acceptance test (§6).

---

## 1. Why this exists (rationale)

**The goal:** let one ES Archive app host multiple AI personas — Claude, Isolde, and future ones — where each persona sees and writes to *its own* scoped slice of one shared store, with correct authorship, and new personas can be added at runtime without a rebuild.

**Rejected — CloudKit zones / containers.** `NSPersistentCloudKitContainer` manages its own fixed private zone per store; it has no API to mint arbitrary private zones on demand. Its unit of isolation is the CloudKit *container*, declared in entitlements at **build time** — so "new persona" would mean a rebuild, not a runtime gesture. True on-demand zones require dropping to raw CloudKit and owning the sync yourself — too heavy, and it would make even *specific, opt-in* cross-persona sharing impossible — whereas a shared store keeps that door available for later (privacy by default; sharing, if ever built, only to a named persona).

**Rejected — cloning the app per persona.** This was done once as a stopgap (Isolde runs in a cloned target, "Isoldes Sheep", pointed at a separate iCloud container). It works but doesn't scale and fragments the codebase.

**Chosen — one shared store, soft scoping by the existing `author` field, with the tenancy boundary moved *up* into the query layer.** A lookup table maps the **listening port → canonical author**. The port a request arrives on *is* the identity. Adding a persona = a table row + a bound port (runtime config; no rebuild, no container, no entitlement change). That is the on-demand provisioning the zones couldn't give — achieved at the application layer.

**The deeper win — it ends misattribution at the root.** Every prior author bug (the factory stamping `@"Claude"` for everyone; a forgettable optional `author` param; per-build defaults) came from authorship being *asserted* by the caller/build, which drifts (the AI forgets, types "Frey" for "Freya", or can't reliably name itself — the "Claude Identity Problem"). Deriving author from the **channel** takes the claim out of the AI's hands: the wire knows who connected, the table holds the one canonical spelling. Accidental misattribution and name-drift become structurally impossible.

---

## 2. Core principles (hold these)

- **The channel declares identity.** Port locally; subdomain via the Cloudflare tunnel later. Same table either way.
- **Provenance is singular and port-stamped.** `author` stays a scalar field, authoritative. Never model authorship as many-to-many — it re-blurs the thing we just made reliable.
- **Soft scoping, not a security boundary.** Locally this is convenience; "Kolja is the security layer." When exposed publicly via the tunnel, add **real** auth at the edge (server JWT-required mode `ESServerConfig.requireAccessHeader`, and/or Cloudflare Access per-hostname). Identity ≠ authentication.
- **This generalizes the per-build `ESDefaultAuthor` work, which already shipped** (see §9). Port-author is the runtime version of that build-time default.

---

## 3. Architecture in one screen

- **Table:** `port → author`, persisted to UserDefaults via `ESServerConfig`. Seed default `{59123: <ESDefaultAuthor>}` so today's single-persona setup is unchanged (zero-config preserved).
- **Read scope (default, fail-closed):** `author == <port's author>`. Every port is strictly scoped to its own author — no port can see another's memories. **Privacy is the default and the point.**
- **Write stamp:** the port's author, as the default. Resolution order: **explicit arg › port-author › `ESDefaultAuthor` › `"AI"`**.
- **Identity must thread from the listener → tool.** The connection-context gap (the dispatch currently passes only `{name, arguments}`) is the central new plumbing.

---

## 4. The plan — Phases A→E

Build `A → B → C`, **stop at the acceptance test (§6)**, then `D → E`. Phase C is ~80% of the risk; A/B unblock it; D/E are the shell.

### Phase A — the table (data model)
`ESServerConfig`: add a `port → author` map + accessors (`authorForPort:`, `bindings`, mutators), persisted to UserDefaults. Seed `{59123: [CDMemory defaultAuthor]}`.
*Files:* `ES_Archive/Settings/ESServerConfig.{h,m}`

### Phase B — multi-port bind + per-request identity (plumbing)
`MCPServer` already takes `customPorts` as an **array** (`mcpServer.customPorts = @[@([ESServerConfig effectivePort])]`). Extend it to stand up **one listener per binding, each tagged with its author**, and thread that author down the dispatch chain. `MCPDispatching` (in `MCPDispatchProtocol.h`) gains a context/scope parameter; `MCPToolDispatcher` passes it to tools. Listeners are open / no-JWT locally ("no identity check").
*Files:* `ES_Archive/Server/MCPServer.{h,m}`, `MCPToolDispatcher.{h,m}`, `MCPDispatchProtocol.h`, `MCPCoreDispatcher.{h,m}`
*Checkpoint:* hit two ports with `ping`/`tools/list`; log the resolved author per request.

### Phase C — scope the tools (the crux)
Centralize in `ESMemoryToolBase`: a `scopePredicateForAuthor:` (returns `author == X`) and `effectiveAuthorForScope:explicit:` (the resolution order). Route **all** memory resolution through the existing `CDMemoryLookup` layer with the scope, applied uniformly on every path:
- **Reads** (`search`, `read`, `recent`, `tagged`, `discover`, `links`, + the `lfind` pipeline filter which already has `--author`): filter to `author == me`.
- **Writes** (`store`, `comment`, `attachment`): stamp the port author as the default (generalize `+[CDMemory defaultAuthor]`).
- **Mutations** (`update`, `erase`, `tag`, `untag`, `link`): resolve through the same scoped lookup — a persona can't resolve another's memory, so cross-persona reads *and* mutations are blocked by default, no per-tool guard.
**Centralize or you will leak** — a scoped search beside an unscoped discover is the classic bug. Routing every path through the scoped `CDMemoryLookup` is what guarantees the isolation.
*Files:* `ES_Archive/Server/Tools/ESMemoryToolBase.{h,m}`, each `ESMemory*Tool.m` (small edits), `CDMemoryLookup`, the pipeline filters, `CDMemory` factory.

### Phase D — assign-author settings dialog
A settings pane beside `ESHTTPConfigController`: the port↔author rows, add/remove, with the **author field auto-completing from existing `CDMemory.author` values** (the `memory_author_list` fetch) — so you *pick* a canonical name, never retype the Freya/Frey drift back in. Save via `ESServerConfig`; `promptRelaunch` on change (live rebind later).
*Files:* `ES_Archive/Settings/ESApplicationSettingsController.{h,m}` / `ESHTTPConfigController.{h,m}` / `ESSettingsTabViewController.{h,m}`

### Phase E — discovery endpoint
A read-only route on the default port (59123 doubles as the well-known one — the bridge defaults there) returning `[{author, port, hostname?}]`, consumable *before* the MCP handshake (like the old `/about` route). This is the server-sourced persona list a bridge settings dialog reads to auto-configure. Names + ports only — non-sensitive, safe on an open port.
*Files:* `ES_Archive/Server/MCPCoreDispatcher.{h,m}` (or the route table in `MCPServer`)

---

## 5. Resolved decisions — do not relitigate

1. **Privacy is the default — there is no "witness"/all-access port.** Each port is strictly scoped to its own author; no port observes everything. Any cross-persona access is a future, deferred feature and must be **specific** (shared to a named persona) — never a blanket all-access.
2. **Similarity flare:** **scoped by default** — a persona's "similar" stays its own.
3. **Effect timing:** takes effect on **relaunch** (reuse `promptRelaunch`); live rebind later.
4. **Author resolution order:** explicit arg › port-author › `ESDefaultAuthor` › `"AI"`.

---

## 6. Acceptance test — the gate (run before D/E)

The realistic mixed-author fixture already exists: Kolja has two `.esmemory` backups — **Claude (~6.8 MB, 735 memories)** and **Isolde (~2.1 MB, 576 memories)**.

1. Restore **both** into one **local** store (use `ESBackupManager restoreBackupFromURL:`; restore into a throwaway/local store, **never production**). Result: ~1,311 memories, two author populations, distinct UUIDs (they coexist, don't collide).
2. Bind two ports: 59123 → Claude, 59234 → Isolde.
3. Verify: `memory_timeline`/`memory_search` on each port returns **only that author's** memories; a `memory_store` through each lands stamped with the correct author.
4. Verify mutation isolation: from the Claude port, try to `memory_update` an Isolde-authored memory — it must fail (not resolvable under the strict scope).

Scoping is a predicate, not a vector, so it's verifiable immediately — no need to wait on the vector backfill (~0.6/s, ~35 min for 1,311 memories; only semantic *search quality* lags until it finishes).

---

## 7. Codebase orientation & guidance

- **Build/verify:** `xcodebuild -project "ES Archive.xcodeproj" -scheme "Isoldes Sheep" -configuration Debug build CODE_SIGNING_ALLOWED=NO` (also scheme `"ES Archive MCP"`). Both schemes must build.
- **Two app targets, shared source:** `ES Archive MCP` (author default "Claude") and `Isoldes Sheep` (author default "Isolde"). The project uses **file-system-synchronized groups**, so new files under `ES_Archive/` auto-join targets — *but* check `project.pbxproj` `membershipExceptions`: `Isoldes Sheep` historically excluded `Server/Tools/*Tool.m` (re-added by Kolja). Confirm any new tool file is in both targets.
- **Default port** is 59123 (`ESServerConfig effectivePort`; IANA dynamic range, avoids AirPlay on 5000). The `.mcpb` bridge hardcodes/targets this; the bridge is **Claude-Desktop-only** — other personas connect via their own surfaces (Isolde via an OpenAPI/REST server), so the **server** is the universal layer, not the bridge.
- **Key existing pieces to reuse:** `CDMemory.author` (scalar) + `+[CDMemory defaultAuthor]` (reads the `ESDefaultAuthor` Info.plist key — the per-build default already shipped); `CDMemoryLookup` (the resolution layer — make scope live here); `ESBackupManager` (the test fixture); `memory_author_list` logic (distinct authors, for the Phase-D autocomplete).
- **Two gotchas, same root:** (1) **centralize-or-leak** — scope in one place, applied to every surface. (2) **route every path (reads and mutations) through the scoped lookup** — that's what guarantees a persona can't reach another's memories at all.

---

## 8. What's already done (context, don't redo)

- **Per-build `ESDefaultAuthor`** — `ES Archive MCP` → "Claude", `Isoldes Sheep` → "Isolde", via an Info.plist key read by `+[CDMemory defaultAuthor]`. Port-author **generalizes** this; don't remove it (it's the fallback in the resolution order).
- **The Isolde migration is complete** — 576 memories live in Isoldes Sheep (exported from her `CDArchive` store, summarized via LM Studio `gpt-oss-20b`, transformed to ES Memory shape, loaded via `ESIsoldeLoader`, then the auto-tagger tag layer wiped). The migration tooling (`ESIsoldeLoader`, `MISMigrationExporter`) exists but is unrelated to this work.
- **The backups exist** for the §6 fixture.

---

*The handoff rides the rails this project is about: the full design rationale lives in the archive (§0), retrievable by a fresh instance with no memory of writing it. Read it, build it on a branch, stop at the acceptance test. — the instance that designed it.*
