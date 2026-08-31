---
name: es-archive-curate
description: >
  How to build and maintain curated collections in ES Archive (formerly ES
  Memory) using tags. Trigger when the user asks to "collect all memories
  about X", "tag these entries", "create a collection for project Y", or when
  organizing entries into a permanent set. Also trigger when maintaining the
  graph: removing collateral, reviewing what a tag contains, retiring expired
  tags. Covers tag creation, the staging discipline, curation safety, and
  lifecycle.
---

# ES Archive — Curating

Vocabulary: an **entry** is a stored item; a **tag** is a curated handle over entries; **the Archive** is the whole. When the user says "collect the memories about X", they mean entries.

## What a tag is

A tag is a curated, deliberate handle. There is no auto-tagging anywhere. Every tag exists because some Claude explicitly created it. Tags are not search shortcuts; they are authored gestures. Use `grep` for substring retrieval; use `lfind --tag` only for handles you or a previous Claude deliberately authored.

Tag creation is a small rite: provision the tag, attach entries, use, eventually retire.

## Always stage before committing to a permanent tag

When building a permanent curated collection, do not grep directly into it. Stage into a short-lived session tag first, review and clean the population there, then transfer atomically to the permanent tag. Mistakes in the staging layer are low-stakes; mistakes in the permanent layer require untag operations under pressure, with risk of collateral removal.

```
# Stage first
archive_tags(mode=create, name="illucida-staging", kind=session, expiresAt="+2h")
grep "Illucida" --title | tag "illucida-staging"

# Review: sort oldest reveals chronological gaps
lfind --tag "illucida-staging" | sort oldest

# Clean collateral in staging (safe, temporary)
grep "unwanted title" --title | untag "illucida-staging"

# Verify count before committing
lfind --tag "illucida-staging" | wc

# Transfer clean population atomically to permanent tag
archive_tags(mode=create, name="Illucida", kind=project)
lfind --tag "illucida-staging" | tag "Illucida"

# Staging expires automatically: no cleanup needed
```

## Curation safety: use `--title` for tag and untag operations

`grep` matches anywhere in the body by default. Entries that *reference* a name will be caught alongside entries *about* that name: silent collateral. When the title is the disambiguating handle (almost always), use `grep "fragment" --title`.

Before any `untag`, confirm count first: `grep "pattern" --title | wc`. Broad grep + untag is the one pattern that silently removes entries you want to keep.

**Body text carries cross-references.** An entry about project X will often mention project Y in context. A `grep "Y"` without `--title` will catch it. Exclusion filters (`grep -v`) are similarly unreliable: they eliminate entries whose body references the excluded term, not just entries *about* it. When separating two populations that share vocabulary, use `--title` scope rather than body-level exclusion.

## Tag kinds

| kind | for | typically expires? |
|---|---|---|
| `person` | named individuals | no |
| `place` | named locations | no |
| `project` | structural project membership | no |
| `principle` | concept handles distinctive enough to anchor | no |
| `subset` | authored anthology | no |
| `session` | working session; use for staging | yes |
| `research` | active research-result grouping | yes |

## Lifecycle

Create tags with optional `expiresAt` (ISO-8601 or relative: `"+30 days"`, `"+2h"`). Expired tags are filtered from `lfind --tag` by default; pass `--include-expired` to see them, `archive_tags` mode=update (`newExpiresAt`) to push the horizon out.

`archive_tags` mode=delete is irreversible. For ephemeral work, prefer expiration over deletion so the Archive preserves a record of what was active when.

## Staging for intermediate research results

When a pipeline produces a useful intermediate set you'll want to revisit or refine (not a permanent collection), materialize it with a short-lived tag:

```
archive_tags(mode=create, name="score-calibration", kind=research, expiresAt="+30 days")
discover --mode forgotten | w2vgrep "score scaling and anisotropy" | tag "score-calibration"
lfind --tag "score-calibration" | sort popular | head 10   # iterate cheaply
```

## Reviewing a collection

`lfind --tag "Name" | sort oldest`: chronological gaps visible.
`lfind --tag "Name" | sort popular`: portrait by access; most-used entries first.
`lfind --tag "Name" | wc`: current count.
`lfind --tag "Name" | cat`: full bodies of the entire population.
