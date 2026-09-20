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

These files sit outside `ES_Archive/` deliberately: that folder is a synchronized
Xcode group, and six files all named `SKILL.md` would collide when flattened into
Resources. Instead the **"Bundle Claude skills"** build phase in both app targets
stages `skills/claude/<name>/SKILL.md` into the app's `Resources/Skills/<name>/`,
so every build carries the skill text that matches its tool surface.

**Distribution: the app installs them.** The Claude Skills card of the Connect
window (Help ▸ Connect ES Archive…) opens `ESSkillInstallController`: one
row per skill with Read (the SKILL.md in a sheet) and Install, which turns gray
with a green checkmark once the skill has been handed over.
Install packs the skill as a `.skill` zip with ESZip, writes it to
`~/Library/Application Support/ES Archive/Skills/`, and opens it in Claude Desktop
**by bundle identifier** — never through the Launch Services `.skill` handler,
which ChatGPT also claims. Claude Desktop shows its own confirmation per skill and
replaces an earlier copy of the same name. An app update is therefore a skill
update again: the drift this directory exists to prevent is caught at build time.

`sync-skills.sh` remains for the developer's own machine (Claude Code reads
`~/.claude/skills` directly) and for the manual claude.ai upload.
