# ES Archive — notes for Claude

- **Skills:** edit only `skills/claude/`. `skills/codex/` belongs to Codex; never
  modify it. Deploy with `scripts/sync-skills.sh`. See `skills/README.md`.
- Build through `ES-Archive.xcworkspace`, not the bare project (it cannot resolve
  the ObjCTokenizer and GCDWebServer submodules on its own).
- **Agents:** `.claude/agents/` holds read-only roles over the Archive
  (librarian, gardener, curator, scribe). They load `skills/claude/` and never
  restate it; see `.claude/agents/README.md`.
