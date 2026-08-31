# Privacy Policy

**ES Archive** (formerly ES Memory)
Last updated: August 30, 2026

## Overview

ES Archive is a memory server for Claude and other MCP-compatible clients. **ES Archive MCP** speaks MCP over stdio to the client that spawns it and opens no network listener; **ES Archive Server** runs the same engine behind a web server bound to your machine's loopback interface (`127.0.0.1`). Neither collects or transmits any data to the developer or to third parties.

## Data Flow

```
Claude Desktop / Code  ──stdio──> ES Archive MCP (engine + local Core Data store)
LM Studio / HTTP client ──localhost HTTP──> ES Archive Server (engine + local Core Data store)
```

- **Local only**: ES Archive MCP communicates over stdio and a local UNIX-domain socket between its own sessions; it accepts no network connections at all. ES Archive Server binds its web server to `127.0.0.1` and accepts no external or remote connections. This traffic never leaves your machine.
- **Storage**: entries are stored in a Core Data (SQLite) database on your machine, in the app's sandbox container.
- **iCloud sync (optional)**: the store uses CloudKit to sync with **your private iCloud database** (`iCloud.com.elarity.electric-sheep`), signed in with your own Apple ID. This is the only activity that leaves your machine in normal operation, and it goes exclusively to Apple's CloudKit service under your account. If you are not signed into iCloud, everything stays local.
- **Embedding**: semantic search runs on a bundled on-device model (EmbeddingGemma via Core ML). Text is never sent anywhere for embedding.
- **Remote access (opt-in)**: ES Archive opens no remote access on its own. If you deliberately expose a persona through a [cloudflared](https://www.cloudflare.com/products/tunnel/) tunnel, that traffic leaves your machine under your own Cloudflare account and its authentication — a choice you make and control.

## Data Collection

ES Archive collects **no data**. Specifically:

- **No analytics or telemetry** are sent anywhere
- **No third-party servers** are contacted — network use is limited to Apple CloudKit sync of your own private database (and any cloudflared tunnel you set up yourself)
- **No data** is shared with the developer or any third party
- Diagnostics are written only to the local system log on your machine

## Third-Party Sharing

No data is shared with any third party.

## Contact

For questions about this privacy policy, open an issue at:
https://github.com/apocryphx/ES-Archive/issues
