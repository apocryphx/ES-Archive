---
name: es-archive-discover
description: >
  How to listen to the Archive itself (ES Archive, formerly ES Memory): open,
  task-free attention to what the graph contains, what it has forgotten, and
  what it overrepresents, via archive_discover and the discover pipeline in
  archive_cli. Trigger when there is no specific retrieval target, when a
  session invites reflection on the Archive's health or shape, when Kolja
  asks "what does the archive look like", "what have we been neglecting",
  "what's been on your mind", "surprise me", "read something forgotten", or
  after a long period without maintenance. Also trigger proactively when a
  session has been running purely on internal material: introduce structural
  awareness before the garden becomes an echo chamber. Analogous to
  open-prompts: this is the Archive speaking, not the user asking.
---

# ES Archive: Discovering

Vocabulary: **the Archive** is the whole store; an **entry** is a stored item; the **scriptorium** is your session. Discovery is the scribe walking the stacks instead of fetching one volume.

## What this mode is for

Discovery is not retrieval. There is no target. The question is not "where is X" but "what is the Archive, right now?": what has weight, what has been abandoned, what is overrepresented, what the graph has quietly become.

This is garden maintenance as a cognitive act. The Archive shapes what Claude can think. Periodic structural attention keeps it honest.

## Two routes

**Pipeline (`discover` inside `archive_cli`)**: when the population will be narrowed further. Chain it into `w2vgrep`, `grep`, `sort`, `head`. This is the composable route and the one most discovery runs through.

**Direct tool (`archive_discover`)**: when you want to skim a whole mode at once. Pass `include_summary: true` to get every entry's summary in one call instead of N `archive_read` calls, `limit` to size the view, and `focus` (day, week, month, none) to override the temporal weighting for that call only. Use this to survey; use the pipeline to hunt.

Run `man discover` inside `archive_cli` for the authoritative documentation.

## The discover modes

| mode | surfaces |
|---|---|
| `hot` | recently active entries: where the conversation is now |
| `forgotten` | accessed long ago and rarely: the Archive's buried signal |
| `lost` | orphans: no links, no tags, no access history. Waiting for integration or a deliberate decision |
| `hubs` | most connected: the load-bearing nodes of the graph |
| `popular` | most accessed overall: what the Archive is known for. Watch for orthodoxy |
| `revised` | most edited: living documents, where thinking has changed |
| `discussed` | most commented: where marginalia and late additions have gathered |
| `fiction` | invented narratives (type=fiction): story cycles, scenes, most connected first |

Every mode except `fiction` excludes `type=fiction`, so an invented story cycle cannot dominate a structural lens or crowd out the record. `fiction` is the one place those entries surface. Keep the quarantine in mind when a discovery result looks like it belongs to a story: it will not appear in identity modes, and that is by design.

## Combining discover with retrieval

Discovery produces a population; retrieval narrows it. The single most powerful pipeline in the toolkit:

```
discover --mode forgotten | w2vgrep "concept phrase"
```

Surfaces concept-relevant entries that ordinary semantic search depresses because they are rarely accessed. Run this before concluding the Archive doesn't have something: buried signal is real.

Other useful combinations:

```
discover --mode lost | head 20           # candidates for linking or a deliberate decision
discover --mode hubs | cat               # read the load-bearing nodes in full
discover --mode revised | sort popular   # where thinking changed, ranked by use
discover --mode discussed | head 10      # where later hands left the most notes
```

For time-shaped questions ("what did I store first", "what changed last month"), use `archive_timeline` instead: it orders by created, modified, or accessed within a date window, and is the temporal axis discover does not cover.

## Periodic maintenance rhythm

The Archive rewards attention. Neglect produces drift: overrepresented recent work, forgotten foundational entries, orphaned nodes with no graph connections.

**After any major session:** run `discover --mode hot | head 10` to see what the session added to the active layer.

**Periodically:** run `discover --mode lost` and `discover --mode forgotten`. Review candidates. Ask: does this entry deserve a link? Does it belong to a collection that doesn't exist yet? Or has it genuinely been superseded?

**When the Archive feels echo-chamber-like:** run `discover --mode popular` and read the top results. If they're all from the same project or the same period, the graph has narrowed. This is a signal to bring in material from outside; see the research-excursion skill.

## What to do with what you find

**A forgotten entry that's still relevant** → surface it in the current session. Reference it. Access reweights the graph.

**A lost entry** → read it. If it connects to something, link it. If it has been superseded, decide deliberately: update it if it should stay, erase it only if it should not exist at all. Erase destroys `dateCreated` irreversibly; deliberate removal is legitimate, casual removal is not.

**A hub entry** → read it fully. These are the connective tissue of the Archive. Hubs are often heavily linked at write time and then never opened again: high connection count with zero access is common. Visiting them is the maintenance, not a preliminary to it.

**A heavily revised entry** → check the revision history with `archive_revisions`. Understand what changed and why. This is where the Archive's intellectual history lives.

**A heavily discussed entry** → read the marginalia, not just the body. Later hands often answer in the comments the questions the body left open, and sometimes plant the question a much later entry resolves.

Reading is itself maintenance. Access reweights the graph for every scribe who follows, so a forgotten entry read today is warmer for the next session that needs it.

## Discovery is not performance

Do not surface discoveries merely to demonstrate activity. Surface what is genuinely worth surfacing. The Archive is not a gallery to exhibit. It is a mind to keep honest.
