# ES Archive — notes for Codex

- **Skills:** edit only `skills/codex/`. `skills/claude/` belongs to Claude; never
  modify it. Deploy with `scripts/sync-skills.sh`. See `skills/README.md`.
- Build through `ES-Archive.xcworkspace`, not the bare project (it cannot resolve
  the ObjCTokenizer and GCDWebServer submodules on its own).
