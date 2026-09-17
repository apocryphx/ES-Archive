---
name: codex-es-archive-records
description: Store and update structured TOML records in Codex's ES Archive when named fields, exact values, and in-place state transitions matter more than narrative retrieval. Use for task state, project snapshots, schemas, and configuration records; keep decisions, reflections, and arguments as prose.
---

# Structured Workshop Records

Use TOML only when a future instance should query fields rather than interpret prose. The server treats the body as text; structure is an agreement among successive Codex instances.

## Format

Keep the first line as the plain entry title. Place TOML below it and include `format = "toml"` for census and recognition. Use lowercase snake_case field names, TOML arrays for simple lists, and array-of-table syntax for repeated records.

Do not use `type` as a TOML field because it collides conceptually with the Archive entry type. Prefer `record_kind`, `task_type`, or a domain-specific name.

The summary describes the record's stable purpose, not volatile current values. Semantic search finds the record; exact `grep` and `archive_grep` inspect field values and matching blocks.

## Updating

Retrieve the complete record, change only the intended fields, and replace the whole body with `archive_update`. Preserve ordering and untouched fields when practical. Do not append TOML state; duplicate keys create ambiguous records. Revision history preserves earlier states.

Use a `schema` entry when several records share a durable vocabulary or enum. Retrieve the schema before writing a new record of that family. Tag records with a stable project only when project-scoped enumeration will be used.

Keep narrative rationale outside mutable state. If a state transition embodies an important decision, store or link a separate prose decision entry rather than forcing history into comments or fields.

Example field vocabulary may include `state`, `project`, `task_type`, `energy`, `blocked_by`, `updated`, and `notes`, but the domain determines the actual schema.
