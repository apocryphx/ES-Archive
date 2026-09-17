# ES Archive Skills — canonical copies

These are the **source of truth** for the ES Archive skill suite (overview, store,
research, curate, discover, toml). They document the MCP tool surface implemented
in `ES_Archive/Server/Tools/` and the pipeline surface in `ES_Archive/Server/Pipeline/`
— so they are versioned here, next to the code they describe.

**When a tool definition changes, update the affected skill in the same commit.**
That is the whole point of keeping them here: the July 2026 drift (skills advertising
`memory_create_tag` and friends months after the consolidation into `memory_tags`)
happened because skill text lived outside version control.

Deployment: the local folders `~/Claude/Skills` and `~/Documents/Claude/Skills`
are deploy targets, not sources. After editing here, run:

```
scripts/sync-skills.sh
```

which copies each `SKILL.md` out and rebuilds the `.skill` zip packages. If the
skills are also registered by upload (claude.ai → Settings → Capabilities), the
repacked `.skill` files must be re-uploaded there — that step is manual.

These files are documentation only; they sit outside `ES_Archive/` deliberately,
since that folder is a synchronized Xcode group and would bundle them wholesale.

**Distribution: download, not the app bundle.** The skills are published for
download and installed by hand; the apps neither carry nor install them.

This replaced an in-app route that proved too unreliable to keep: a "Bundle
Claude skills" build phase staged this directory into each app's
`Resources/skills/`, and an **Install Claude Skills…** command handed the
`.skill` packages to Claude Desktop for its own per-skill confirmation. Both the
build phase and the command are gone. Consequences worth knowing:

- An app update is no longer a skill update. Skills and the tool surface they
  document now version independently, so **a skill change has to be published
  separately** — the drift this directory exists to prevent is now a release
  step rather than something the build guarantees.
- Nothing reads `Resources/skills/` any more, and nothing writes it.
