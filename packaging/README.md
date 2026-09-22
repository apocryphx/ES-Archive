# Packaging — ES Archive MCP (`.mcpb`)

This directory packages the **ES Archive MCP** app (the stdio target, built from
this repository) into a notarized `.mcpb` extension for Claude Desktop.

> Historical note: this used to live in a separate `ES-Archive-Bridge` repo, back
> when the shipped artifact was a stdio↔HTTP *forwarder*. As of v3.0.0 the
> `.mcpb` contains the full in-process server, and packaging was folded into the
> engine repo. The bridge repo is retired.

## ⚠️ The manifest `name` is the upgrade-continuity key

`bundle/manifest.json` sets `"name": "es-archive-bridge"`. Claude Desktop keys
extension *upgrades* on this slug — changing it makes an existing install see a
brand-new extension instead of an update, producing a duplicate with doubled
tools. **Do not change it.** Users never see it: the `display_name` is
"ES Archive". The slug is an internal continuity key, not a user-facing name.

## Release process

1. In Xcode, Archive the **ES Archive MCP** scheme (the scheme keeps the product name) → Distribute App →
   **Direct Distribution** (signs Developer ID, notarizes, staples) → export
   the `.app`.
2. Pack it:
   ```bash
   packaging/package-mcpb.sh "/path/to/Archive MCP.app"
   ```
   The script verifies the Developer ID signature + notarization staple, strips
   iCloud/Finder xattrs (`ditto --norsrc`), and packs with `zip -ry` to preserve
   the embedded framework's symlinks (`mcpb pack` breaks them → Gatekeeper
   rejects the app). It never re-signs. Output: `packaging/ES-Archive-MCP.mcpb`.
3. Attach `ES-Archive-MCP.mcpb` to a GitHub release on this repo.

`bundle/server/` (the staged app) and `ES-Archive-MCP.mcpb` are gitignored — the
binary artifact lives on releases, not in the tree.

## MCP registry

The official registry (registry.modelcontextprotocol.io) lists ES Archive as
`io.github.apocryphx/es-archive`, pointing at the `.mcpb` on the matching
GitHub release. `registry/server.json` is the template; `publish-registry.sh`
fills in the version (from `bundle/manifest.json`) and the bundle's SHA-256,
creates or updates the `v<version>` release with the `.mcpb` attached, waits
for GitHub to serve it, and publishes. One-time setup: `brew install
mcp-publisher` and `mcp-publisher login github`. Run the packaging step above
first; `--dry-run` validates without releasing or publishing.
