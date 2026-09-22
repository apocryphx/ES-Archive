# Claude Code agents for ES Archive

Roles over the Archive, each a thin definition that loads the skills in
`skills/claude/` and composes the MCP tools. None of them adds a tool and
none of them writes to the Archive: they read, they propose, and they hand a
report back to the session that called them. The session, or Kolja, decides
what enters the Archive. This follows the mechanism/policy decision recorded
in the Archive on May 24, 2026: policy lives in agents, the store stays pure.

| Agent | Give it | Get back |
|---|---|---|
| `archive-librarian` | one question | a dated scorecard: claims separated, trajectory oldest first with provenance, where the Archive disagrees with itself, what is settled, what is open, sources |
| `archive-gardener` | nothing | the Archive's shape: hot, forgotten-but-alive, lost with a proposal each, hubs, echo-chamber check, revisions, marginalia, the last thirty days, three actions |
| `archive-curator` | nothing, or a tag name | a proposal over the tag catalog: merges, reclassifications, retirements, collateral, each with the exact call |
| `archive-scribe` | material from a session | a ready-to-store draft (title, type, body, summary, existing tags, verified links), or a recommendation to append to an existing entry, or to store nothing |

All run on Sonnet. The work is methodical, not generative; the expensive
model is the one that asked.

The only write any of them makes is the librarian's session tag, a working
bucket with a two-hour expiry that it deletes before returning. The curator
and scribe may call `archive_tags` in list mode only.

Every agent inherits the persona of the MCP connection that spawned it, so
it sees that persona's slice of the Archive and nothing written by another
persona. A zero result under another persona's tag is the scoping boundary,
not evidence of absence. The scribe's first test run surfaced exactly this.

Claude Code reads this folder at session start. After adding or editing an
agent, restart the session for it to appear by name.
