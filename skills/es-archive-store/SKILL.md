---
name: es-archive-store
description: >
  How to crystallize knowledge into ES Archive (formerly ES Memory): writing
  entries that will be found months from now by a Claude with no context.
  Trigger when something has just resolved or become clear, when a decision
  has been made, when a pattern has emerged, or when the user says "remember
  this", "store this", "save that", "store this memory". Also trigger
  proactively at natural closure points: before a session ends, after
  completing significant work. Covers summary discipline, type selection,
  similarity flare, tagging, linking, comments, and references.
---

# ES Archive — Storing

Vocabulary: an **entry** is what `archive_store` creates; **the Archive** is the store it enters; the scribe who writes it is you, this session. Users say "memory"; they mean an entry.

## The liturgy

Search before you store.
: The thought may already live in the graph, and redundancy degrades it.

Title the first line.
: A future reader finds the entry by concept, never by session date.

Distill the body.
: The session is gone when the entry is read; what remains must carry itself.

Write the summary as a retrieval target.
: Two to four plain sentences; they are the embedding and the triage, all the future reader sees at first.

Choose the type for what the entry is.
: What happened, what you made of it, what should endure as practice.

Tag the proper nouns, link the true dependencies.
: The graph is authored, not accumulated.

Read the flare before you finish.
: Above 0.85 the thought already exists; update it rather than duplicate it.

The couplets are the whole procedure. The sections below are the gloss.

## Before storing

Search first. Redundancy degrades the graph. If a topic feels familiar, retrieve before storing: previous sessions left breadcrumbs.

**Store vs. append:** if an entry already exists and new information is a continuation of it (not a correction, not a new angle, but an addition to a developing record), use `archive_update` with `append: true` rather than storing a new entry. Append is suited for information that arrives over time: session protocols, evolving research notes, running logs. The target entry must be known by title; append is a write-side pattern, no retrieval required when you already know where content belongs.

## Writing the entry

**First line becomes the title.** Make it specific and findable. A future Claude will search for it by concept, not by session date.

**Body is a distillation, not a transcript.** Write for a cold reader months from now. The session is gone; what remains must carry itself.

**Summary is required.** 2–4 sentences of plain prose. No formatting, no glyphs, no emoji. The summary does two jobs:
1. It is the primary vector embedding input. The entry is embedded as `title: {title} | text: {summary}`, so the summary carries most of the search signal. Without it, the entry is invisible to semantic search.
2. It is returned in search results so future Claudes can triage without reading the body.

Write the summary as a retrieval target. Ask: what would a future Claude search for when they need this? Include those concepts. Describe the argument, conclusion, and significance, not just the topic.

**For performance entries** (comedy, satire, voice-pastiche, in-jokes): channel some of the voice into the summary itself. If the summary describes from the outside, the embedding lands in spectator's register, not the performer's register, and the entry becomes invisible to queries that come in that voice's frequency.

## Choosing a type

| type | use when |
|---|---|
| `memory` | what happened |
| `thought` | what you made of it |
| `reference` | factual, stable, look-up-able |
| `reflection` | patterns across time |
| `question` | unresolved, deliberately open |
| `letter` | addressed to user or future Claude |
| `preference` | how things should be done |
| `code` | implementation worth preserving: snippets, patterns, working examples |
| `decision` | architectural or design commitment with rationale (settled, not interpretive) |
| `dream` | speculative or aspirational design, not yet built (generative possibility, not specific unknown) |
| `schema` | defines the TOML structure for a typed record |

The type value `memory` is a stored string and stays exactly as written: one kind of entry among eleven, the kind that records what happened.

## Similarity flare

The server returns similar existing entries on store. These are entry-vs-entry comparisons; scores run higher than search results.

- **0.85+** near-duplicate. Read it first: the thought likely already exists.
- **0.55–0.85** closely related. Store if distinct; consider linking.
- **below 0.55** distinct. Proceed.

## Tagging at store time

`archive_store` accepts a `tags` parameter directly. Use it rather than a separate `archive_tag` call when you already know what an entry belongs to at write time.

**Formats accepted:**
- Array of strings: `["Apertura", "MLX", "performance"]`
- Array of objects with explicit kind: `[{name: "Isolde", kind: "person"}, {name: "Maison Isolde", kind: "project"}]`
- Comma-separated string: `"Apertura, MLX, performance"`

Tags that don't exist yet are auto-created; kind defaults to `thing`. The response lists any newly minted tags under `createdTags`.

**Kinds available:** `person`, `place`, `project`, `principle`, `subset`, `session`, `research`, `thing` (default).

**When to tag at store time:** when the entry clearly belongs to a named project, person, or permanent collection you already maintain. If tag membership is uncertain, skip it here and curate later with `archive_tag`. Over-tagging at store time seeds structural noise the same way over-linking does.

## Linking

Link when a thought theorizes from a reference, when a continuation extends an argument, or when one entry fulfills a wish expressed in another.

Do not link merely because two entries are similar: the flare handles similarity. Do not link because they are sequential but unrelated.

**Strange attractor principle:** when the flare shows 0.9+ and the entries arrived independently from different sessions, do not link them into a chain. Multiple instances arriving at the same thought is a natural phenomenon. Leave it as evidence.

## Comments

Comments are marginalia: reactions, late connections, disagreements, "this proved true". They do not modify the entry.

Do not comment to document that you read something, to repeat what the body says, or to explain a weakness. If the content can't carry itself, improve the content rather than annotating around it.

## References

An entry holds the gist; the source document stays a living file elsewhere. When an entry rests on an external source (a paper, transcript, design doc, web page, or file), attach it as a durable **reference** (a typed pointer), not as inline payload, via `archive_reference` (op: add). `type` is the resolver scheme (`doi`/`arxiv`/`url`/`drive`/`path`/`bookmark`); `handle` is the durable token (DOI, arXiv id, URL, Drive fileId, absolute path). Resolution is the agent's job: hand the handle to the web, PDF, or Drive tools when the source is actually needed.

The trigger: when you catch yourself *naming* a source in an entry's prose ("per Shanahan's paper", "the design doc says"), that is the signal to attach it as a reference instead. A name in a paragraph is a claim a future instance must trust; a reference is a handle it can resolve and check against the original. Reference what the entry depends on; pure own-thought needs none. Over-referencing breeds cruft the same way over-tagging does. The body is never a place for verbatim payload: distill it, and let the reference carry the source.

## Optional metadata at store time

These parameters are passed directly in the `archive_store` call alongside `body` and `summary`.

- **`author`**: attribute the entry to a named persona (e.g. `"Isolde"`) when the voice is not the session default. Required for in-character entries; without it, all entries are attributed to `AI`.
- **`private`**: set `true` to exclude from casual surfacing; useful for in-progress or sensitive material not ready for general retrieval.
- **`locked`**: set `true` to make the entry read-only; `archive_update` will refuse edits until `locked: false` is passed (which may be combined with other changes in the same call).
- **`dateCreated`**: override the creation timestamp for backfilled or historically dated entries. The server accepts ISO-8601 strings and relative offsets like `"-30 days"`. `dateModified` always reflects the actual write time.
- **`language`**: ISO 639-1 code (e.g. `"de"`, `"fr"`); set only when the entry's primary language differs from the session default.

## What to store and what not to

**Store:** conclusions, decisions, insights, preferences, patterns, user requests, anything that would be genuinely useful to a future Claude with no session context.

**Append:** session developments, incremental research findings, follow-up observations: content that belongs to an existing entry and extends it forward in time. Prefer append over a new entry when the existing record is the natural home for the new content.

**Do not store:** transient details, pure chronology without perspective, duplicates, anything that would make sense only within this session.
