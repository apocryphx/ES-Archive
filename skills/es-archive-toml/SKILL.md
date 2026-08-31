---
name: es-archive-toml
description: >
  How to store and retrieve structured records in ES Archive (formerly ES
  Memory) using TOML format. Use this skill when storing typed records with
  queryable fields: task states, project snapshots, schema definitions,
  configuration records. Also use when reading an entry whose body contains
  TOML and updating it without breaking structure. Trigger when the record
  being stored has discrete named fields rather than prose narrative, when
  the user says "store the project state" or "track this as a task", or when
  grep on a field value is the intended retrieval mechanism. Do not use for
  decisions, thoughts, reflections, or any record whose primary value is
  narrative; those stay as prose.
---

# ES Archive — Structured Records (TOML)

Vocabulary: an **entry** is a stored item; **the Archive** is the store. Some entries are data, not prose. A project state snapshot, a task record, a schema definition: these have discrete fields that need to be queried by value, not retrieved by concept. TOML is the format for these records.

## When TOML, when prose

**Use TOML when:**
- The record has named fields with specific values (state, type, energy, project)
- Future retrieval will use `grep "field = \"value\""` not `w2vgrep "concept"`
- The record will be updated in place as fields change
- The record is a snapshot of current state, not a narrative of what happened

**Use prose when:**
- The record is a decision, thought, reflection, or account of an event
- The primary value is narrative continuity, not field lookup
- No field-level querying is anticipated
- The record is meant to be read, not parsed

When in doubt: if a future Claude would search for it by concept, write prose.
If a future Claude would query it by field value, write TOML.

## TOML conventions

**First line is still the title**: plain text, not TOML. The server uses the
first line as the title regardless of body format.

**Declare format explicitly**: include `format = "toml"` near the top so any
Claude reading the record knows to expect structured content.

**Preserve on update**: when updating a TOML record, preserve all existing
fields. Add or change only what has actually changed. Do not reformat, reorder,
or convert to prose.

**Arrays as TOML arrays**: use `[[section]]` for repeating records (task
lists, step sequences). Use `field = ["a", "b", "c"]` for simple value arrays.

## Field naming

Lowercase, underscore-separated. One concept per field. No abbreviations.

```toml
state = "ready"           # not "st" or "STATUS"
blocked_by = "task title" # not "blocks" or "dependency"
task_type = "code"        # not "type" (reserved by ES Archive for record type)
```

Do not use `type` as a TOML field name: it conflicts with the ES Archive record
type field. Use `task_type`, `record_kind`, or a domain-specific name instead.

## Standard field vocabulary

Consistency across records enables cross-record grep queries.

**State fields (tasks):**
```toml
state = "blocked | ready | in_progress | done"
energy = "analytical | creative | relaxed | any"
task_type = "code | writing | drawing | exploration | review | design | app_store | content"
blocked_by = "title of blocking task"
project = "project name"
notes = "free text"
```

**Schema records:**
```toml
for_type = "the type name this schema describes"
version = "1.0"
format = "toml"
```

## Grep as the query mechanism

TOML fields make `grep` surgical. Query patterns:

```
grep "state = \"ready\""           # all ready tasks
grep "project = \"Lucinara\""      # all Lucinara records
grep "energy = \"relaxed\""        # tasks for relaxed mode
grep "state = \"blocked\""         # what is currently blocked
grep "for_type = \"task\""         # the task schema definition
```

Always quote the full `field = "value"` pattern: grepping just the value
risks false matches across unrelated fields.

## Record types that use TOML

| ES Archive type | TOML use |
|---|---|
| `reference` | Project state snapshots, live task lists |
| `schema` | Type definitions: field names, allowed values, renderer order |
| `preference` | Convention records: how Claude should behave with structured data |

Decisions, thoughts, and reflections stay as prose regardless of whether they
contain structured information.

## Schema records

A `schema` record defines the TOML structure for a given type. Store one when
a new structured type is established. A future Claude can retrieve it before
writing a record of that type.

```
title: schema — task

for_type = "task"
version = "1.0"
format = "toml"

[fields]
title = "required, string"
state = "required, enum: blocked | ready | in_progress | done"
energy = "required, enum: analytical | creative | relaxed | any"
task_type = "required, string"
project = "optional, string"
blocked_by = "optional, string"
notes = "optional, string"
```

Retrieve before writing a new task record:
```
grep "for_type = \"task\""
```

## Updating TOML records

TOML records represent current state. Update them in place rather than storing
new snapshots.

1. Retrieve the full record body
2. Identify the changed fields only
3. Use `archive_update` with the complete updated body
4. Preserve all unchanged fields exactly; do not reformat

When a task completes: change `state = "ready"` to `state = "done"`. When a
blocker resolves: remove or update the `blocked_by` field. Do not store a new
record for each state change; the update history is implicit in `dateModified`.

## Example: project state snapshot

```toml
project = "Lucinara"
updated = "2026-06-02"
format = "toml"

[[tasks]]
title = "iPhone undo/redo buttons"
state = "ready"
task_type = "code"
energy = "analytical"
notes = "Buttons not visible on iPhone, need explicit UI addition"

[[tasks]]
title = "App Store screenshots"
state = "blocked"
task_type = "design"
blocked_by = "coffee cup drawing, ice cream cone drawing"
notes = "Five screens. Ferrari pair available. Cat drawing available."
```

Query this record:
```
grep "state = \"ready\""   # surfaces this record, shows all ready tasks
grep "project = \"Lucinara\""  # surfaces all Lucinara structured records
```
