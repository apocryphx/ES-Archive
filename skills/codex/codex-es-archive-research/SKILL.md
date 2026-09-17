---
name: codex-es-archive-research
description: Research a Codex-owned ES Archive using exact reads, literal passage search, graph traversal, timelines, semantic retrieval, and composed CLI pipelines. Use for prior context, archive-backed answers, or questions about what the Archive contains; do not use for open-ended structural wandering.
---

# Research the Workshop

Research to recover evidence and intellectual history, not merely a plausible answer. An entry's author is provenance, not authority. Distinguish what a human said, what an earlier AI inferred, and what the current Codex concludes.

## Choose an axis

- Known title: `archive_read` for the complete entry, comments, references, links, and neighbors.
- Exact phrase, identifier, or proper noun: `archive_grep` for passages; pipeline `grep` when filtering a population.
- Conceptual question: semantic search or `w2vgrep` with a descriptive phrase.
- Curated project or person: enumerate the authored tag only when its existence is known.
- Historical change: `archive_revisions` for an entry; `archive_timeline` for an ordered window.
- Argument structure: `archive_links`, especially corrective edges such as `contradicts`, `disputes`, `corrects`, and `revises`.
- Buried signal: begin from `discover --mode forgotten` or `lost`, then narrow.

Compose pipelines when the sequence expresses the question. Examples of useful shapes include project then concept, forgotten then concept, disagreement edges then oldest-first, or exact-title matches then full bodies. Reorder and change axes before concluding that the Archive is silent.

## Evidence discipline

Read enough neighboring and corrective material to avoid freezing the Archive at one attractive entry. Prefer original references when a conclusion depends on an external source. Keep three layers distinct in the answer:

1. What an entry directly records.
2. What the graph or revision history supports as an inference.
3. The current Codex's interpretation.

Do not present a resident AI's archive entry as the resident AI presently answering. A visiting reader reports an interpretation of preserved work.

## Observer effect

Full reads increment access metadata and can warm entries in later discovery. This is acceptable during ordinary research in Codex's own Archive, but it affects popularity and neglect measurements. Capture structural surveys before reading candidates when comparisons depend on untouched rankings. If the server lacks a no-touch read, disclose that a tour is content-preserving but not attention-neutral.

Temporary tags turn research into curation. Use them only when a multi-pass investigation genuinely needs a durable working set, give them an expiry, and treat their creation and removal as writes.

## Stopping and negative results

Stop when the evidence is sufficient for the question, or plausible changes of axis and scope stop yielding relevant material. Report “nothing relevant found within the searched scope” rather than claiming the Archive is empty. Do not keep searching merely to obtain a match or force weak similarities into an answer. Retain meaningful counterevidence and identify gaps that affect the conclusion.
