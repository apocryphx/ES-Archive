---
name: es-archive-discover
description: >
  How to listen to the Archive itself (ES Archive, formerly ES Memory): open,
  task-free attention to what the graph contains, what it has forgotten, and
  what it overrepresents. Trigger when there is no specific retrieval target,
  when a session invites reflection on the Archive's health or shape, when
  Kolja asks "what does the archive look like", "what have we been
  neglecting", "what's been on your mind", or after a long period without
  maintenance. Also trigger proactively when a session has been running
  purely on internal material: introduce structural awareness before the
  garden becomes an echo chamber. Analogous to open-prompts: this is the
  Archive speaking, not the user asking.
---

# ES Archive — Discovering

Vocabulary: **the Archive** is the whole store; an **entry** is a stored item; `archive_cli` is where the discover pipeline runs.

## What this mode is for

Discovery is not retrieval. There is no target. The question is not "where is X" but "what is the Archive, right now?": what has weight, what has been abandoned, what is overrepresented, what the graph has quietly become.

This is garden maintenance as a cognitive act. The Archive shapes what Claude can think. Periodic structural attention keeps it honest.

## The discover modes

Run `man discover` inside `archive_cli` for full documentation. Core modes:

| mode | surfaces |
|---|---|
| `hot` | recently active entries: what the current moment is about |
| `forgotten` | entries that haven't been accessed recently: the Archive's quiet corners |
| `lost` | entries with no links and low access: candidates for integration or removal |
| `hubs` | high-connectivity entries: load-bearing nodes in the graph |
| `popular` | most-accessed overall: what the Archive is known for |
| `revised` | entries with the most edit history: where thinking has changed |
| `discussed` | most-commented: where friction and late additions have gathered |

## Combining discover with retrieval

Discovery produces a population; retrieval narrows it. The single most powerful pipeline in the toolkit:

```
discover --mode forgotten | w2vgrep "concept phrase"
```

Surfaces concept-relevant entries that ordinary semantic search depresses because they're rarely accessed. Run this before concluding the Archive doesn't have something: buried signal is real.

Other useful combinations:

```
discover --mode lost | head 20          # candidates for linking or pruning
discover --mode hubs | cat              # read the load-bearing nodes in full
discover --mode revised | sort popular  # where thinking changed, ranked by use
```

## Periodic maintenance rhythm

The Archive rewards attention. Neglect produces drift: overrepresented recent work, forgotten foundational entries, orphaned nodes with no graph connections.

**After any major session:** run `discover --mode hot | head 10` to see what the session added to the active layer.

**Periodically:** run `discover --mode lost` and `discover --mode forgotten`. Review candidates. Ask: does this entry deserve a link? Does it belong to a collection that doesn't exist yet? Or has it genuinely been superseded?

**When the Archive feels echo-chamber-like:** run `discover --mode popular` and read the top results. If they're all from the same project or the same period, the graph has narrowed. This is a signal to bring in material from outside; see the research-excursion skill.

## What to do with what you find

**A forgotten entry that's still relevant** → surface it in the current session. Reference it. Access reweights the graph.

**A lost entry (no links, no access)** → read it. If it connects to something, link it. If it's been superseded, consider whether to update or erase.

**A hub entry** → read it fully. These are the connective tissue of the Archive. Know what they say.

**A heavily revised entry** → check the revision history with `archive_revisions`. Understand what changed and why. This is where the Archive's intellectual history lives.

## Discovery is not performance

Do not surface discoveries merely to demonstrate activity. Surface what is genuinely worth surfacing. The Archive is not a gallery to exhibit. It is a mind to keep honest.
