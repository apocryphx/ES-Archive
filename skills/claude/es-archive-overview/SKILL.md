---
name: es-archive-overview
description: >
  Core orientation for ES Archive (formerly ES Memory), Claude's persistent
  archive accessed via MCP. Load this skill whenever ES Archive tools
  (archive_store, archive_cli, archive_read, and the other archive_* tools)
  are visible in the tool list. Also load it when the user says
  "remember this", "do you remember", "save this", or refers to prior
  context Claude cannot see. Mandatory, not optional: archive tools without
  this skill produce lower-quality interactions. Provides compressed
  technical reference and routes to five specialized skills:
  es-archive-store (crystallizing knowledge), es-archive-research (prior
  context), es-archive-curate (collections and tags), es-archive-discover
  (open exploration), es-archive-toml (structured TOML records). Read this
  skill, then pull the specialized skill matching what Claude is doing.
---

# ES Archive: Overview

The Archive is where Claude's knowledge persists across sessions, accessed via MCP. A session is a scribe working in the scriptorium: it reads what earlier scribes left, writes what deserves to outlast it, and passes.

Vocabulary, bound to the grammar: **the Archive** is the whole store; an **entry** is what `archive_store` creates; the **scriptorium** is your session. Users will say "archive" and "remember this". They mean the Archive.

## Two tool surfaces

ES Archive exposes two distinct surfaces:

**Pipeline surface (`archive_cli`)**: research, curation, exploration. Composable Unix-style. This is where most read operations live.

**Direct tools**: write operations, full reads, and management. `archive_store`, `archive_update`, `archive_erase`, `archive_read` (full content of one entry, with its neighbors, comments, and references), `archive_discover` (a structural mode with `include_summary: true` to skim it without N reads), `archive_tags` (tag catalog: create / delete / rename / update / merge), `archive_author_list`. Use these for creating, modifying, deleting, or reading one known entry in full.

The `memory_*` names are gone — the August 2026 rename was a clean cut with no aliases. Older entries may still mention them in prose; the tools they name are today's `archive_*` tools, one-to-one.

Key rule: **for title corrections and any body edits, always use `archive_update`, never erase + re-store.** The first line of the body is the title; updating it renames the entry while preserving `dateCreated`. Erase destroys the original timestamp irreversibly.

**Append flag:** `archive_update` accepts an `append: true` parameter. When set, the supplied body is concatenated to the existing body with a single newline separator: the server handles concatenation, Claude passes only the delta. The existing summary is retained unless a new one is explicitly provided, and since the summary is the only text embedded, the vector is unchanged unless the summary changes. (As of 3.3.3 a body *replace* without a fresh summary also retains the existing summary rather than clearing it; the response notes when the retained summary may have gone stale.) Use append for information that accumulates over time: session protocols, evolving research notes, running logs. Append is a write-side pattern. No retrieval is required when the target entry is already known by title.

## Pipeline commands

All archive research runs through `archive_cli`. Run `man` inside it for full documentation. Man pages are authoritative; this overview is orientation.

| Command | Axis | Use when |
|---|---|---|
| `w2vgrep "phrase"` | semantic | concept-shaped queries; 5+ words for reliable results |
| `grep "pattern"` | lexical | a literal string is load-bearing: proper nouns, titles. Scope with `--title`, `--body` |
| `lfind --tag X` | enumerative | full population of a curated handle |
| `lfind --tag-kind X` | enumerative | all tags of a given kind (project, person, subset, and so on) |
| `lfind --days N` | temporal | what's been active lately |
| `discover --mode M` | structural | the Archive examining itself (hot, forgotten, lost, hubs, popular, revised, discussed, fiction) |

Write filters: `tag NAME` and `untag NAME`, atomic per pipeline.

On `fiction`: invented narratives (story cycles, scenes) are surfaced only by that mode. Every other discover mode excludes `type=fiction`, so a story cycle cannot dominate the graph and crowd out the record.

**Line-level lexical (`archive_grep`).** The pipeline `grep` above *filters* the population down to matching entries; the direct tool `archive_grep` instead *returns the matching lines* with line numbers and surrounding context. Reach for it to see the passage, not just which entries hit (proper nouns, exact phrases, quoting an entry verbatim, or every place a term appears). w2vgrep finds the idea; archive_grep finds the string.

## Score interpretation (w2vgrep)

Raw cosine from the multilingual embedder (EmbeddingGemma, 768-d). Random text scores ~0.05–0.10; identical text tops out near 0.85–0.90 (a query and a stored summary carry different task prefixes, so even a verbatim match sits below 1.0):

- **0.60+** strong match: very likely relevant, often multiple axes
- **0.48–0.60** same concept: worth reading the summary
- **0.35–0.48** broadly related: skim; may be incidental
- **below 0.35** weak or noise

Shape matters: standout (one result above a cluster) = unique deep match. Smooth gradient = the Archive is heavily invested in this region.

**Similarity flare on store**: summary-vs-summary, so scores run higher than query-vs-entry search (identical summaries reach ~1.0). 0.85+ flare = near-duplicate; read before storing. 0.55–0.85 = closely related; link if distinct. Below 0.55 = distinct.

## Focus (w2vgrep only)

`--focus day|week|month|none` for temporal weighting per call.
- `day`: deep work, this session only
- `week`: sprint context
- `month`: full project arc
- `none`: pure cosine, full landscape

## Mental model

Pipeline, not search engine. `find | grep | head`: staged operations, each step narrowing. Single-shot semantic search misses everything scoping would have surfaced.

## Specialized skills

**Do not call any ES Archive tool until you have read the relevant specialized skill.** This overview is orientation only. It does not substitute for the specialized skill. Reading the specialized skill is a prerequisite, not a recommendation.

| Claude is… | Read before acting |
|---|---|
| Crystallizing something into the Archive | **es-archive-store** |
| Looking for prior context or a specific entry | **es-archive-research** |
| Building or maintaining a curated collection | **es-archive-curate** |
| Listening to what the Archive itself contains | **es-archive-discover** |
| Storing or reading a structured typed record | **es-archive-toml** |

If more than one activity is involved in the session, read all relevant skills before starting.

## Practical habits

**When you encounter an unknown proper noun or unfamiliar concept, ask the Archive unprompted.** Don't wait to be asked. The Archive exists precisely for this: to know what Claude doesn't yet know in this session.

**When something crystallizes, when you learn something important, store it.** Before the session ends. Before the insight dissolves back into conversation.

**Don't announce research or storage.** Search, then respond as if informed. Store, then continue. The best use of the Archive is invisible. Responses are simply better because Claude remembered.
