# Packaging

ES Archive MCP and ES Archive Server ship through the **Mac App Store only**.
There are no GitHub releases and no MCP registry entry; technically inclined
users build from source.

- `app-review/` — App Review notes and screenshots.
- `chatgpt/` — the ChatGPT / Codex plugin.

## Claude Desktop connector

Claude Desktop is connected from inside the app (**Help ▸ Connect ES
Archive…**). `ESConnectHelper` builds a thin connector `.mcpb` in code that
points Claude Desktop at the installed binary; nothing here is involved.

> ⚠️ The connector's manifest `name` is `es-archive-bridge`. Claude Desktop keys
> extension upgrades on this slug, and it is what carries users of the retired
> Developer ID `.mcpb` over to the App Store app as an update rather than a
> duplicate extension with doubled tools. **Do not change it.**

## History

Until the App Store build was approved, ES Archive MCP was also distributed
directly: a Developer ID, notarized `.mcpb` attached to GitHub releases and
listed in the MCP registry (`io.github.apocryphx/es-archive`). That path
(`package-mcpb.sh`, `publish-registry.sh`, `bundle/`, `registry/`) was retired
on 2026-09-25; see git history before that date.
