# Packaging — ES Archive MCP (`.mcpb`)

This directory packages the **ES Archive MCP** app (the stdio target, built from
this repository) into a notarized `.mcpb` extension for Claude Desktop.

> Historical note: this used to live in a separate `ES-Archive-Bridge` repo, back
> when the shipped artifact was a stdio↔HTTP *forwarder*. As of v3.0.0 the
> `.mcpb` contains the full in-process server, and packaging was folded into the
> engine repo. The bridge repo is retired.

## ⚠️ The manifest `name` must stay `es-memory-bridge`

`bundle/manifest.json` sets `"name": "es-memory-bridge"`. **Do not "clean up"
this slug.** It is the identifier Claude Desktop keys extension *upgrades* on —
changing it makes every existing install (which upgraded from the bridge era)
see a brand-new extension instead of an update, producing a duplicate with
doubled tools. Users never see it: the `display_name` is "ES Archive". The slug
is an internal continuity key, not a user-facing name.

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
