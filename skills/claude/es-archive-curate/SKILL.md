---
name: es-archive-curate
description: >
  How to build and maintain curated collections in ES Archive (formerly ES
  Memory) using tags, via archive_tags, archive_tag, and the tag/untag
  pipeline stages in archive_cli. Trigger when the user asks to "collect all
  memories about X", "tag these entries", "create a collection for project
  Y", "make a subset", or when organizing entries into a permanent set. Also
  trigger when maintaining the graph: removing collateral, reviewing what a
  tag contains, merging duplicate tags, retiring expired tags. Covers tag
  creation, the staging discipline, curation safety, kinds, and lifecycle.
---

# ES Archive: Curating

Vocabulary: an **entry** is a stored item; a **tag** is a curated handle over entries; **the Archive** is the whole. When the user says "collect the memories about X", they mean entries. Tagging is rubrication: the red headings a scribe adds so a later hand can find its way through the volume.

## What a tag is

A tag is a curated, deliberate handle. There is no auto-tagging anywhere. Every tag exists because some Claude explicitly created it. Tags are not search shortcuts; they are authored gestures. Use `grep` for substring retrieval; use `lfind --tag` only for handles you or a previous Claude deliberately authored.

Tag creation is a small rite: provision the tag, attach entries, use, eventually retire.

## Two ways a tag gets attached, and why it matters

**Pipeline stage `tag NAME`** attaches an *existing* tag to every entry in the population, atomically. An unknown name is an error, by design: tags are deliberate, so create explicitly. Provision with `archive_tags(mode=create, ...)` first.

**Direct tools `archive_tag` and `archive_store`** connect-or-create: a name that doesn't exist yet is minted on the spot with kind `thing`. Convenient for a single entry, but it skips the moment where kind and expiry get decided. When either matters, provision via `archive_tags` first, then attach.

Tag names are unique across all kinds, matched case- and diacritic-insensitively. `create` on a taken name returns `already_exists` and creates nothing; there is no overwrite.

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
lfind --tag "illucida-staging" | tag "Illucida" | head 5   # tag passes the population through; head confirms what landed

# Staging expires automatically: no cleanup needed
```

## Curation safety: use `--title` for tag and untag operations

`grep` matches title and body by default. Entries that *reference* a name will be caught alongside entries *about* that name: silent collateral. When the title is the disambiguating handle (almost always), use `grep "fragment" --title`.

Before any `untag`, confirm count first: `grep "pattern" --title | wc`. Broad grep + untag is the one pattern that silently removes entries you want to keep.

**Body text carries cross-references.** An entry about project X will often mention project Y in context. A `grep "Y"` without `--title` will catch it. There is no exclusion filter in the pipeline (no `grep -v`), and that is deliberate: body-level exclusion would eliminate entries whose body merely references the excluded term. When separating two populations that share vocabulary, use `--title` scope and positive matches, and clean the remainder by hand in staging.

**Moving entries between tags** is one pipeline: `lfind --tag "old-name" | untag "old-name" | tag "new-name"`. Both writes commit atomically.

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
| `thing` | the uncategorized default that connect-or-create assigns | should be reclassified with `archive_tags` mode=update |

Enumerate by kind with `lfind --tag-kind project`; intersect tags with `lfind --tags "A, B"` (all named tags required).

## Lifecycle

Create tags with optional `expiresAt` (ISO-8601 or relative: `"+30 days"`, `"+2h"`). Expired tags are filtered from `lfind --tag` and `lfind --tag-kind` by default, so an expired tag returns zero results; pass `--include-expired` to resurface a paused thread, or `archive_tags` mode=update (`newExpiresAt`) to push the horizon out. `newExpiresAt=null` clears expiry and makes the tag permanent.

`archive_tags` mode=rename changes a name in place. mode=merge moves every entry from a source tag into a target and deletes the source: the right tool when two hands authored the same collection under different names.

`archive_tags` mode=delete is irreversible. For ephemeral work, prefer expiration over deletion so the Archive preserves a record of what was active when. Deleting a tag never touches entries, only the tag-to-entry edges.

**Catalog hygiene** lives in `archive_maintenance`: `dedupeTags` reconciles same-name duplicates that multi-device CloudKit sync can leave behind (uniqueness is enforced at creation only), and `pruneTags` hard-deletes tags expired more than `graceDays` ago so the dead rows stop syncing. Both are safe to run independently of vector state.

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
`lfind --tag "Name" | links`: the graph neighborhood of the collection, without loading bodies.
