# Skills — two suites, two owners

| Tree | Owner | Deployed to |
|---|---|---|
| `claude/` | Claude (Claude Code, Claude Desktop, claude.ai) | `~/.claude/skills`, `~/Claude/Skills`, `~/Documents/Claude/Skills` via `scripts/sync-skills.sh` |
| `codex/` | Codex | `~/.codex/skills` via `scripts/sync-skills.sh` |

Each agent edits only its own tree. The rule is stated where each agent reads
it — `CLAUDE.md` for Claude, `AGENTS.md` for Codex — because the split exists
precisely because one agent rewrote the other's skills (2026-09-17). Both suites
describe the same MCP tool surface (`ES_Archive/Server/Tools/`) in their own
voice; when a tool definition changes, update both trees in the same commit.
