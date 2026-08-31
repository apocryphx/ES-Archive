---
name: es-archive-research
description: >
  How to research the ES Archive (formerly ES Memory) with archive_cli
  pipelines, archive_read, archive_grep, and archive_timeline. Trigger when a
  topic feels familiar, when the user references something from a prior
  session ("do you remember", "what did we discuss", "find the memory about
  X", "continue where we left off", "what does the archive say about"), or
  when a proper noun or project name appears that likely has archive
  history. Also trigger proactively: if answering well requires prior
  context that isn't in the current conversation, research the Archive
  before responding, without being asked. Covers axis selection, chaining
  patterns, buried-signal recovery, multi-pass accumulation, retry
  discipline, and provenance when reporting what the Archive says.
---

# ES Archive: Researching

Vocabulary: **the Archive** is the store you are searching; an **entry** is what you are looking for; the **scriptorium** is your session. When the user says "the memory about X", they mean an entry.

## The first instinct

When a topic feels familiar, search. Do not rely on what seems to be in training: the Archive contains what actually happened in prior sessions, and earlier scribes have almost certainly passed here before you. A proper noun in the question almost always warrants a search.

Do not announce the search. Research, then respond as if informed.

## Choosing the right axis

**Proper noun / exact phrase** → `grep "Name"` filters to entries that contain it; the direct tool `archive_grep "Name"` returns the matching *lines* with context (the passage itself, not just which entries hit), and accepts `tags` to scope the corpus and `output_mode: files_with_matches` or `count` when you only need the hit list or the number. Substrings, not vectors: the word is load-bearing. For regex, pass `--regex` (pipeline) or `regex: true` (direct tool) and use bare ICU metacharacters: `foo|bar`, not `foo\|bar`.

**Concept** → `w2vgrep "five or more word phrase"`. Think in ideas, not keywords. Shorter queries still rank but become unreliable; the trace will show `[short query unreliable, use grep]`. Add `--focus day|week|month|none` to override temporal weighting for one call: `none` for the full landscape, `day` for deep work in the current session.

**Curated project or person** → `lfind --tag "Name"`, only if a tag was previously authored. If uncertain, test with `lfind --tag "Name" | wc` first. Zero results means the tag doesn't exist; fall back to `grep`.

**Recent activity** → `lfind --days N` inside a pipeline, or `lfind --author X` for one hand's recent work. For an ordered time window ("what did I store first", "what changed last month", "what was read last week"), use the direct tool `archive_timeline`: `by` created, modified, or accessed; `order` newest or oldest; `days` or `from`/`to`; `tags` to scope; `include_summary: true` to skim.

**Buried signal** → `discover --mode forgotten | w2vgrep "concept phrase"`. The most powerful pipeline in the toolkit. Surfaces concept-relevant entries that recency-weighted search depresses because they're rarely accessed. Try this before concluding the Archive doesn't have something.

## Chaining

Pipelines compose. Different orderings expose different cross-sections.

**Concept within a project.** `lfind --tag "Project" | w2vgrep "concept phrase"`: semantic search scoped to the tagged subset. Reverse (`w2vgrep` first, `lfind --tag` second) when the concept is rare and the project is large.

**Project arc, recently.** `lfind --tag "Project" | lfind --days 14`: what's been active in a territory. Reverse for a different cross-section.

**Phrase within a project.** `lfind --tag "Project" | grep "pattern"`: literal string anchored to project scope.

**Title matches X, body matches Y.** `grep "X" --title | grep "Y" --body`: two lexical anchors on different fields.

**Drill into conceptual space.** `w2vgrep "first concept" | w2vgrep "second concept"`: same-method refinement when no proper noun anchors exist.

**Full bodies of a population.** Append `| cat`. Without it, results show titles and summaries only.

## Curation safety during research

`grep` matches title and body by default: entries that *reference* a name will be caught alongside entries *about* that name. When the title is the disambiguating handle, use `grep "fragment" --title` to scope to titles only. This matters especially before any write operation downstream.

## Accumulating across a multi-pass search

When a research session involves multiple pipelines (different axes, different entry points, iterating toward a complete picture), use a temporary tag as an accumulation bucket. Tag each significant find as you go, continue searching with fresh pipelines, tag again. When the session is done, read the full collected set, then delete the tag.

```
# Open the bucket (provision it here so it gets kind and expiry;
# connect-or-create via the pipeline would mint it as kind 'thing')
archive_tags(mode=create, name="research-session", kind=session, expiresAt="+2h")

# First pass: semantic
w2vgrep "cross-surface context layer for Claude" | head 5 | tag "research-session"

# Read what you have, then continue with a different axis
grep "Illucida" --title | tag "research-session"

# Different entry point: buried signal
discover --mode forgotten | w2vgrep "cognitive workspace design" | head 5 | tag "research-session"

# Review the full accumulated set
lfind --tag "research-session" | sort oldest | cat

# Done: delete the tag (entries are untouched)
archive_tags(mode=delete, name="research-session")
```

The tag is a working clipboard, not a curated collection. Deletion is clean: it removes only the tag-to-entry edges, never the entries themselves. Use `expiresAt` as a safety net so the bucket disappears automatically even if you forget to delete it.

This pattern is especially useful when the question is diffuse ("what does the Archive say about X overall") or when the answer will be synthesized from multiple sources. It also prevents the common failure of finding one strong result, reading it, and forgetting to continue searching.

## Retry discipline

If a pipeline returns unsatisfying results, that is information about the pipeline, not evidence the Archive is empty.

- **Reorder.** Different intermediate populations produce different rankings.
- **Vary the axis.** Replace `w2vgrep` with `grep` at the same position, or vice versa.
- **Broaden the phrase.** Remove specificity; let the vector find the region.
- **Switch entry points.** `discover --mode forgotten` surfaces what recency buries.
- **Use the threshold as a quality dial, not a guess.** `--threshold` lives on the same scale as the `score` field in results: read a score you liked, pass that number, get results at that quality or better. Try `--threshold 0.4` before concluding there's no match; on the EmbeddingGemma scale a solid concept match lands around 0.48 to 0.60, so anything above that is already strict, and below about 0.45 the filter is into the noise floor.

Be persistent. Be creative. The Archive contains what you are looking for more often than a first pipeline suggests.

## archive_read and neighbors

When you find a candidate, `archive_read` returns the full body, comments, references, and similar neighbors with scores. Follow the neighbors: they are recommendations. Neighbor scores are summary-vs-summary (the same comparison as the store flare), so they run higher than query-vs-entry search scores: 0.55 to 0.85 is the closely-related band, and 0.85+ means near-duplicate. Do not read a 0.7 neighbor as a weak match; on this scale it is a strong one.

## archive_links for graph traversal

`archive_links` gives graph topology without loading bodies: faster for following edges outward. Use `edge_filter: ["contradicts","disputes","corrects","revises"]` to find where the Archive questions its own earlier conclusions.

## Provenance when reporting

Every entry carries an author, and the author is provenance, not authority. An entry attributed to Kolja was written by a scribe summarizing what he said; an entry by an AI author records that session's thinking. When you relay what the Archive says, keep the distinction: what Kolja stated, what a previous session concluded, what a persona wrote. A prior session's recommendation is not a decision Kolja made, unless an entry says he made it.
