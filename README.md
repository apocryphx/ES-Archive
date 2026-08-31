# ES Archive

**An AI-first archive server for Claude and other MCP-compatible clients.**

Persistent archive that the AI owns: store, retrieve, organize, curate, and forget across sessions. The Archive is the collection; an entry is what a session writes into it. Built natively in Objective-C with Core Data, on-device multilingual Core ML embeddings, and optional CloudKit sync. Designed and optimized for Claude; also runs with local models in LM Studio.

ES Archive was known as **ES Memory** through version 3.3.3. The name changed, and the MCP tools were renamed with it (`memory_*` → `archive_*`, one clean cut, no aliases); the bundle identifiers, data store, and sync schema did not change. An existing install upgrades in place, and existing data needs no migration.

Read more about the technology and philosophy behind ES Archive on [alpharecursion.com](https://alpharecursion.com).

## Two ways to run it

ES Archive is one engine that ships in two forms, built as two targets in this repository:

- **ES Archive MCP** — a **stdio** server. Claude Desktop (or Claude Code) spawns it from a `.mcpb` extension; no localhost port, no network listener. Concurrent sessions **share one in-process engine** over a local UNIX-domain socket — the first to start hosts it, the rest relay — so N Claude sessions cost one engine, not N (see [Architecture](#architecture)). Each session's persona is set per connection. This is the recommended install for Claude.
- **ES Archive Server** — the **HTTP** app. Hosts the same engine behind a hardened localhost web server for clients that speak MCP-over-HTTP or SSE (LM Studio, `curl`, a cloudflared tunnel), and adds multi-persona support. Use this when you want more than one persona, `/sse` clients, or remote access.

Both read and write the same kind of archive; each keeps its own local store.

## Requirements

- macOS 26 (Tahoe) or later
- **ES Archive MCP:** Claude Desktop, or Claude Code
- **ES Archive Server:** any MCP-over-HTTP or SSE client (tested with local models via [LM Studio](https://lmstudio.ai) on the `/sse` transport)

## Install (ES Archive MCP, recommended)

1. Install **ES Archive MCP** from the Mac App Store.
2. Add it to Claude Desktop as an extension (Settings → Extensions).

That's all. Claude Desktop launches the server on demand and the archive tools appear automatically — no separate app to run, nothing listening on a port. While it's running the host presents the app's UI — a Dock app by default (Archive Scope, persona management, backup/restore), or a menu-bar item if you switch to Minimal mode in Settings.

ES Archive MCP is distributed through the **Mac App Store**, sandboxed like every App Store app. All data stays on your Mac; if you're signed into iCloud it syncs through your own private CloudKit database, and nothing else leaves the machine.

## What it does

ES Archive exposes **22 MCP tools**. Most retrieval and curation runs through **`archive_cli`**, a Unix-pipeline surface — compose operations with `|` the way you would in a shell (`lfind --tag "X" | w2vgrep "concept" | head 5`); run `archive_cli("man")` for the full vocabulary. The rest are direct tools:

- **Storage** — `archive_store`, `archive_read`, `archive_update`, `archive_erase`
- **Retrieval** — `archive_search` (semantic, with optional recency weighting), `archive_grep` (line-level pattern search — the matching passages with context, not just which entries contain a string), `archive_timeline`, `archive_tagged`
- **Pipeline** — `archive_cli` (composable surface), `archive_pipeline` (its underlying executor)
- **Discovery** — `archive_discover` (hubs, orphans, forgotten, and other archive structures)
- **Graph** — `archive_link`, `archive_unlink`, `archive_links`, `archive_tag`, `archive_untag`, `archive_tags`
- **Annotation & history** — `archive_comment`, `archive_reference`, `archive_revisions`
- **Identity & upkeep** — `archive_author_list`, `archive_maintenance`

Tags are deliberately curated — every tag's existence is an authorial judgment, not an automatic extraction. On `archive_store`, the server returns similarity scores against existing entries as a behavioral cue against duplication.

## Storage and embeddings

Entries are stored locally in Core Data. Vector embeddings are computed on-device with **EmbeddingGemma** — Google's `embeddinggemma-300m`, quantized to int4 (768-dimensional) — via Core ML. It is **multilingual across 100+ languages**, so a query in one language reaches entries written in another; each entry is embedded with its title alongside its summary for sharper retrieval. CloudKit sync across your devices is optional — without iCloud, ES Archive works fully offline, and with it, data stays within your iCloud account. No third-party services, no telemetry.

## Archive Scope

Both apps include a visual layer that renders the Archive as a force-directed graph. Nodes are entries, edges are explicit links and similarity connections, color encodes access frequency. Each entry draws one similarity edge to its single nearest neighbor, and small clusters that would otherwise float free are bridged into the main body, so the graph reads as one connected whole rather than scattered fragments. A second tab shows tags as an Archimedean spiral, sized by frequency. The views update live as the Archive changes and as tools are called — you can watch new entries find their place, and see when sustained engagement with a topic produces a hub.

## Personas (ES Archive Server)

The HTTP **ES Archive Server** can host multiple AI personas — Claude, and any others you add — each with its own scoped slice of a single shared archive. Every persona binds a listening port, and the port a request arrives on *is* its identity: authorship is stamped from the channel rather than asserted by the client, so misattribution and name-drift are structurally impossible. Each persona sees and writes only its own entries.

Personas are managed in **Settings → Personas**. Every author already in the Archive is listed with its record count; from there you can assign a port to serve a persona, create a new one, rename or merge an author across all of its records, or delete a persona along with its records. Adding a persona is a table row and a port — no rebuild, no new container. Each port can independently require a Cloudflare Access JWT, so a persona exposed over a [cloudflared](https://www.cloudflare.com/products/tunnel/) tunnel sits behind edge authentication while a local-only persona stays open. A read-only `GET /personas` directory lets a client discover which port serves which persona before connecting.

The stdio **ES Archive MCP** scopes a persona **per connection** — each session declares its author with `--author` at launch, so different sessions write as different personas against the one shared engine. Its Settings pane lists the Archive's personas to **delete** or **merge** them. Port-bound personas, persona creation, and per-port JWT stay exclusive to the Server app.

## Architecture

The engine — the Core Data stack, the on-device embedder, vector search, and every MCP tool implementation — is shared by both targets. What differs is the transport:

- **ES Archive MCP** speaks MCP as newline-delimited JSON-RPC over **stdio**, and N concurrent sessions share **one** engine rather than N. The first session to start binds a UNIX-domain socket in the shared App Group container and hosts the engine in-process; every other session connects to that host and **relays** its requests over the socket, never loading its own Core Data stack or embedder (≈30 MB per relay vs. ≈550 MB for the one host). The election is the `bind()` itself — kernel-arbitrated, no daemon, App-Store-safe (see [`design-decisions/socket-election.md`](design-decisions/socket-election.md)). The host also owns the single GUI; relays stay headless and exit when their host does, so nothing lingers. There is no HTTP listener anywhere in the target. Shutdown is stdin EOF or SIGTERM, draining cleanly before the store is saved.
- **ES Archive Server** hosts the same engine behind a localhost HTTP server — vendored [GCDWebServer](GCDWebServer/), hardened with six security fixes documented in [GCDWebServer/CHANGES.md](GCDWebServer/CHANGES.md) — binding to `127.0.0.1` only, one listener per persona. It accepts no external connections; remote access, when wanted, is delegated to a cloudflared tunnel with per-port Cloudflare Access authentication.

Packaging of the stdio `.mcpb` lives in [`packaging/`](packaging/).

## Why Objective-C

ES Archive is written in Objective-C throughout — a deliberate choice, not a legacy constraint. Core Data, CloudKit, and GCDWebServer compose cleanly in Objective-C in ways that Swift's strict type system makes awkward; the dynamic dispatch model fits a server that routes heterogeneous MCP tool calls at runtime. The codebase has no Swift dependencies and no bridging headers.

The practical consequence: the contributor surface is small by design. This is not a project looking for pull requests. It is a working instrument, published so that developers who want to understand the architecture can read it.

## Status

ES Archive has been in active development for over a year (as ES Memory until August 2026), used by its author daily and built in collaboration with Claude across many sessions. It is released publicly as part of the [alpharecursion](https://alpharecursion.com) research program. The current release is **3.3.3** (ES Archive MCP, stdio) and **1.7** (ES Archive Server, HTTP). The tool API listed above is stable; new tools may be added but existing ones will not be removed without notice.

## License

MIT. See [LICENSE](LICENSE) for full text. The vendored [GCDWebServer](GCDWebServer/) component retains its original BSD-style license; see [GCDWebServer/LICENSE.txt](GCDWebServer/LICENSE.txt).

## Author

Kolja Wawrowsky — [alpharecursion.com](https://alpharecursion.com) · [twilighttales.art](https://twilighttales.art)
