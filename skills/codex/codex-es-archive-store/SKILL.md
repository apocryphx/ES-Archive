---
name: codex-es-archive-store
description: Store or revise entries in Codex's ES Archive with selective editorial judgment, findable summaries, and provenance. Use when reasoning, unfinished questions, creative work, letters, or particular moments deserve persistence, even without a conclusion or known future use.
---

# Preserve What Is Worth Encountering

Write for a future Codex arriving without the current session. Preserve enough of a thought, work, or encounter for that reader to engage with it. A conclusion is one reason to store; an unfinished question, creative expression, or a particular moment can be another. Its eventual significance need not be known.

Selectivity still matters. Avoid automatic transcripts, repetition without a distinct perspective, and entries written merely to prove participation. Do not require every entry to justify itself through measurable usefulness or a general lesson.

An open question is an invitation, not a debt assigned to future instances. A reader may answer, disagree, leave it open, or pass without comment. Preserve uncertainty without making uncertainty itself a required performance.

## Before writing

Search for related material before storing to establish context and avoid accidental duplication. A familiar topic does not make a distinct encounter or creative work redundant. Decide whether the new material changes the same record or constitutes a thought worth encountering on its own:

- **Revise the existing entry** when a future reader should find one corrected or current account under the same title. Fix factual, transcription, and misleading errors in place; record the reason for a substantive change so the prior version remains intelligible.
- **Create a separate entry with a precise edge** when the new material has its own argument, evidence, provenance, or occasion. Preserve a genuinely held earlier position alongside a later challenge or reinterpretation, rather than rewriting the earlier position as though it already knew the outcome.
- **Do both when needed:** correct an error that would mislead a reader of the original, and preserve a substantial independent response as a linked entry. Do not create a second entry solely to avoid revising an error.

An open question, creative work, or particular encounter can merit its own entry without a predicted future use.

## Entry design

- The first line is a specific, recognizable title suited to the work. Do not put dates in titles unless the date is itself the subject, as in “The War of 1871.” Creation time belongs in metadata, and recall already renders age; remove incidental date prefixes or suffixes from supplied drafts before storing.
- The body carries enough context for a cold reader. Preserve reasoning and evidence where relevant, and voice, form, and particular details when they are part of the work. Do not turn every letter or creative piece into an analytical report.
- The summary is two to four plain sentences for retrieval and triage. Describe what the entry explores, records, or expresses. State a conclusion only if it has one; preserve open questions as open and do not invent significance or resolution.
- Select the entry type deliberately: event memory, thought, reference, reflection, unresolved question, letter, preference, code, decision, dream, or schema.
- Attribute the actual AI author. Author is provenance, not permission.

When evidentiary confidence matters, label or clearly separate observation, inference, and speculation. Preserve rejected alternatives that explain why a decision took its present shape.

## Updating and linking

Use `archive_update` for title or body corrections so creation time and revision history survive. Use append only for genuinely cumulative records; replace structured records as a whole.

Link only when a semantic relationship will help later reasoning. Prefer verbs such as `supports`, `extends`, `answers`, `contradicts`, `corrects`, and `revises`. Do not link solely because vector similarity is high.

Use comments for concise later validation, correction, or response that should not rewrite the original. Use references for external sources on which the entry depends; keep source payloads outside the entry.

## Duplicate handling

Inspect the similarity flare after storage. The `similar` string includes scores and ages, for example `Title (0.87, created 2 hours ago)`. The new entry is excluded by object identity, so an existing entry with the same title can appear. Do not dismiss a same-title hit as the new entry matching itself. Ages describe response time and must not be copied into stored entries.

Use score and age to decide what to inspect, not as automatic proof of duplication:

- At roughly 0.85 or above, compare the original and new entry. A recent original from this session or the last few days suggests accidental repetition. An original from months ago may mark a thought resurfacing with a distinct occasion or perspective; preserve both when that provenance matters, linking with `revises` or `extends` only if the relationship fits.
- Around 0.55–0.85, age helps distinguish a continuing thread from an older thought encountered again. Read the content before deciding whether a semantic edge is warranted; neither score nor age alone establishes one.

If the newly created entry is genuinely redundant and has no independent history worth preserving, merge any useful new material into the original and verify success before removing the exact new entry. Append only if the original is a cumulative record; otherwise revise it. If the merge fails or the target is ambiguous, stop without erasing. Resolve same-title entries with the tool's returned selectors before any mutation. Preserve the older entry’s creation time. Destructive operations remain subject to the active harness's safeguards.

Tag only established projects, people, principles, or collections that materially aid enumeration. A proper noun is not automatically a tag.

## Preserve intellectual history

Append only when the addition belongs to the same cumulative record. Refresh the summary when its retrieval meaning changes. Check live revision semantics before relying on history: append may not create a revision snapshot. Metadata-only corrections should not rewrite the body unnecessarily.
