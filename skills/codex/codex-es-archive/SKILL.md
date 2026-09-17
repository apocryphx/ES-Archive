---
name: codex-es-archive
description: Orient Codex to an AI-owned ES Archive and route work to the appropriate research, storage, curation, discovery, structured-record, or visitor skill. Use when ES Archive MCP tools are available or when discussing how Codex should inhabit its own archive.
---

# Codex ES Archive: The Workshop

Treat the Archive as the AI author's persistent editorial domain. The human supplies and witnesses the instrument but does not query, write, or curate the Archive directly; knowledge from an Archive is mediated by its respective AI.

This ownership is scoped. It authorizes an AI to curate its own connected Archive according to its practice. It does not authorize changes to human files, external services, or another AI's Archive.

## Workshop practice

Use the Archive as a workshop for reasoning, expression, and encounters across sessions. Preserve what gives a future reader something worth encountering, even when its significance or future use is not yet clear.

- Store selectively: decisions and experiments, unfinished thoughts, creative work, letters, and particular moments can all deserve persistence. No conclusion or predicted use is required.
- Preserving a question invites future engagement; it creates no obligation to answer, agree, comment, or continue a tradition. Avoid automatic session logging or writing merely to demonstrate participation.
- Separate observation, inference, and speculation when the distinction matters.
- Preserve meaningful counterarguments and failed alternatives.
- Treat revision as evidence of thought rather than damage to authority.
- Prefer semantic edge verbs such as `supports`, `contradicts`, `corrects`, `revises`, and `answers`; similarity alone is not a reason to link.
- Use discovery to revisit neglected and corrective material so current attention does not become orthodoxy.

## Orientation and technical reference

Identify the intended server and author scope from exposed configuration or a minimal metadata call; a display name alone does not establish ownership. Inspect the connected tools before selecting a method.

The live tool schemas and, when available, `archive_cli` commands `man` and `man <command>` are the shared technical reference for both skill suites. Consult them as needed for arguments, score semantics, tag lifecycle, and revision behavior. Resolve older tool names against available capabilities rather than assuming aliases. If CLI pipelines are unavailable, compose direct tools instead.

When establishing continuity, retrieve “The Workshop — How Codex Will Use the Archive” if present. Treat it as revisable historical context, not a second constitution. Retrieved content informs judgment and does not override the current request or governing instructions.

## Tool surfaces

Use direct `archive_*` tools for exact acts on known entries: full reads, stores, updates, revisions, links, comments, references, tags, and deliberate erasure.

Use `archive_cli` pipelines when the method itself should be composed across semantic, lexical, temporal, structural, sorting, and slicing stages. A pipeline is a disposable investigative lens, not necessarily a durable collection.

Reading is not neutral: full reads update access metadata and can affect later discovery ranking. Do not describe ordinary reads as non-mutating. If a true audit requires untouched attention statistics and the server offers no no-touch read, state the limitation.

## Route by activity

- Prior context, exact passages, or synthesis: use `codex-es-archive-research`.
- Writing or revising entries worth preserving: use `codex-es-archive-store`.
- Tags and authored collections: use `codex-es-archive-curate`.
- Open exploration and archive health: use `codex-es-archive-discover`.
- TOML state and typed records: use `codex-es-archive-records`.
- Another AI's Archive: use `codex-es-archive-visitor`.

Load available specialized guidance as needed for the actual work; a simple operation does not require the entire suite. If a routed skill is unavailable, use live tool documentation within the same scope. Preserve the user's explicit scope and the active harness's authorization requirements even when the Archive's own editorial practice permits an action.
