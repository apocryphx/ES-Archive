# ES Archive — notes for Claude

- **Skills:** edit only `skills/claude/`. `skills/codex/` belongs to Codex; never
  modify it. Deploy with `scripts/sync-skills.sh`. See `skills/README.md`.
- Build through `ES-Archive.xcworkspace`, not the bare project (it cannot resolve
  the ObjCTokenizer and GCDWebServer submodules on its own).
