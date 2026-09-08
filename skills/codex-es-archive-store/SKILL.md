---
name: codex-es-archive-store
description: Store or revise durable knowledge in Codex's ES Archive with sparse editorial judgment, retrieval-focused summaries, provenance, typed entries, and meaningful graph edges. Use when an insight, decision, experiment, implementation pattern, preference, or unresolved question should persist.
---

# Store Durable Reasoning

Write for a future Codex arriving without the current session. Store a crystallized result, not a transcript and not evidence that the session occurred.

## Before writing

Search for the idea first. If an existing entry is the same developing record, append or revise it. If the new work corrects, challenges, or reframes the old work, preserve both and connect them with a precise edge.

Use a new entry when it can stand independently and has a distinct retrieval purpose. Sparse storage keeps the graph legible.

## Entry design

- The first line is a specific, concept-shaped title rather than a session date.
- The body carries enough context, evidence, reasoning, and limitations for a cold reader.
- The summary is two to four plain sentences optimized for future retrieval and triage. State the conclusion and why it matters; do not use ornamental formatting.
- Select the entry type deliberately: event memory, thought, reference, reflection, unresolved question, letter, preference, code, decision, dream, or schema.
- Attribute the actual AI author. Author is provenance, not permission.

When evidentiary confidence matters, label or clearly separate observation, inference, and speculation. Preserve rejected alternatives that explain why a decision took its present shape.

## Updating and linking

Use `archive_update` for title or body corrections so creation time and revision history survive. Use append only for genuinely cumulative records; replace structured records as a whole.

Link only when a semantic relationship will help later reasoning. Prefer verbs such as `supports`, `extends`, `answers`, `contradicts`, `corrects`, and `revises`. Do not link solely because vector similarity is high.

Use comments for concise later validation, correction, or response that should not rewrite the original. Use references for external sources on which the entry depends; keep source payloads outside the entry.

## Duplicate handling

Inspect the similarity flare after storage. A high score is a prompt to compare, not automatic proof of duplication. If the newly created entry is genuinely redundant and has no independent history, remove only that exact new entry and preserve the older entry's creation time. Destructive operations remain subject to the active harness's safeguards.

Tag only established projects, people, principles, or collections that materially aid enumeration. A proper noun is not automatically a tag.
