# ES Archive — notes for Claude

- **Skills:** edit only `skills/claude/`. `skills/codex/` belongs to Codex; never
  modify it. Deploy with `scripts/sync-skills.sh`. See `skills/README.md`.
- ObjCTokenizer and GCDWebServer live in sibling folders (`../ObjCTokenizer`,
  `../GCDWebServer`) so other projects can share them, not submodules. They are
  subprojects of `ES Archive.xcodeproj`, which builds on its own.
- **Agents:** `.claude/agents/` holds read-only roles over the Archive
  (librarian, gardener, curator, scribe). They load `skills/claude/` and never
  restate it; see `.claude/agents/README.md`.
