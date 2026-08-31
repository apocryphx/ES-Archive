# The Owner / Author / Share Model

*From the author category error to a tag-based UNIX permission system — June 28, 2026.*
*Durable copy: the archive memory of this decision was lost in a sync/rebuild rollback (see note at bottom), so this file is the authoritative record.*

A design decision for ES Memory's identity and sharing layer, reasoned out with Kolja over one morning. Recorded so the next instance inherits the rationale trail, not just the schema.

## The category error (the seed)

The single `author` field conflates two things that coincide only in the common case: **origin** (who authored the content) and **ownership** (whose archive owns the record — the tenancy / scope key). Verified in code: `CDMemory` has one `author` attribute and it **is** the scope key — `scopePredicateForAuthor` (`author == me`) threads through every lookup, pipeline, and discover call; there is no separate owner/origin field. The conflation bites sharply: you cannot store "Isolde's essay, in Claude's archive" — set `author=Claude` and you erase that Isolde wrote it; set `author=Isolde` and the scope predicate ejects the record from Claude's archive entirely. Same shape as the `CDAttachment → CDReference` error: one field, two jobs, invisible until they diverge.

## First refinement (Kolja's correction, which simplified it)

A **record** has only one author — the single AI that wrote it (no human writes memories; the archive is the AI's). The plural "co-authors" first reached for (Rubber Duck = Claude + Isolde + Kolja) are the **subject's** co-creators — that is *content*, carried by the reference's own `author` and by proper-noun tags, not the record's author. So provenance is singular: a **field, not an entity**. A separate author field only resurfaces if ownership transfer (`chown`, writer ≠ controller) is ever wanted; defer it. For the record, writer and owner coincide; the one genuinely separate axis, subject-origin, is already handled by references + tags.

## The model — UNIX file permissions

`owner` (one persona) + `group` (membership) + `mode`. Resolves the "multiple owners?" fork: ownership stays **singular**; the relationship is a **group**, not a co-owner set. UNIX's permission bits pre-solve every sharing question (`chgrp` = share, `rm` = owner-only delete, group-write bit = edit rights, other = none = private / fail-closed). Feasibility verified: **one** `NSPersistentCloudKitContainer` ("Electric_Sheep"), ports bind to author-scopes — so sharing is a **scoping** change within one store (one row, many viewers), never cross-store duplication.

## The implementation — tags, not a new entity

- Each persona gets an auto-generated **share tag** of a distinct `kind:"share"`, so it never collides with a content tag (share-with-Isolde ≠ the proper-noun `Isolde` meaning *about* Isolde).
- A memory's set of share tags is its **access-control list** — per-persona grants, more flexible than a single group. `share:Persona` = a named ACL entry.
- `share:all` = the reserved wildcard = the UNIX **"other" / world-readable** bit. Subsumes "public" into the shared axis (so there is no third source). It is **dynamic** — matched at query time, so it auto-includes *future* personas, unlike static per-persona grants.
- **Read-only** for non-authors; only the author edits / deletes / regrants. Others **fork** (copy into their own archive, with a `forked-from` link) to diverge. No shared editing to police.
- **Marginalia** is open to any viewer and needs no extra permission, because it rides the read scope (below).

## The crux (verified — the only real new code)

Every tool today — read **and** write — goes through one scoped lookup (`findScopedMemoryWithTitle:scopeAuthor`, `author == me`). Visibility and write-access are the same gate: you can only find what you authored, so "can edit" rode free on "can see." Sharing breaks that coupling (a non-author can now find a shared memory). So the implementation **splits read scope from write scope**:

- **Read scope (widened):** `author == me OR (a share-tag for me, including share:all)`. Used by read, search, grep, discover, lfind, timeline, tagged, links, revisions — **and `comment`**.
- **Write scope (author-only, unchanged):** update, erase, tag, untag, link, unlink, reference. You mutate only what you authored.

Two lookups (`findReadable` / `findOwned`), ~13 tools routed, no new entity. This is **why** open marginalia needs no permission: `comment` is the one write that rides the read scope — anything you can see, you may annotate, because the margin never touches the author's body. Read-only core, open margins: the conversation grows around a thought without anyone editing it.

## The scope parameter

An **enum, not a bitfield**: `author_only | shared_only | all`. Two sources (mine, shared) yield three nameable states; a bitfield is speculative generality (same over-engineering lesson as the singular-author entity). If a genuinely independent third source ever appears, use an **array** of source names (`["author","shared"]`), never an opaque integer.

**Default = `all`.** Silent omission is the worse failure — the throughline of this whole stretch of work (the author conflation, the undocumented `already_exists`, the attachment payload were all invisibly wrong until needed). At launch nothing is shared, so default-all changes no existing behavior; the cost is future, the benefit is that sharing works the moment it exists. Single-memory lookups by title (read / comment) resolve a shared memory **regardless** of the flag — you named it; if you may see it, resolve it. The flag governs population queries.

## The shared-canon consequence (Kolja's final correction)

`share:all` gives the archive a **shared-canon tier**: one memory — a skill, a protocol, a settled decision — authored once, visible to every persona, maintained by its author, forkable. But injection (`CLAUDE.md`, a persona's system prompt) is **per-persona, never shared** — so for canon that must reach all personas, the retrieved `share:all` memory is the **only** home. This **hardens default-all**: retrieved canon that is opt-in is a document nobody opens. The residual tradeoff that does not go away: injected canon is always-present but private; retrieved `share:all` canon is shared but must be **actively found** — reach vs reliability. Shared canon's weak point is not storage but **surfacing**, and surfacing is per-harness — the canon is equally owned by every persona but not equally reachable.

## The full mapping

| UNIX | ES Memory |
|---|---|
| owner (user) | `author` — writes / deletes |
| group / named ACL | `share:Persona` tags |
| other (`o+r`) | `share:all` — world bit, dynamic |
| mode bits | read / write scope split |
| anyone-with-read may annotate | open marginalia |
| `cp` | fork |

The entire permission system falls out of the existing tag mechanism plus a single read/write scope split — no new entity. Disciplines that shaped it: verify against code before designing; the worse failure is the invisible one (omission); resist the over-built version of a fixed-shape thing.

---

*Note (June 28, 2026): this decision was first stored as an archive memory, but a check minutes later found that **all of June 27's archive writes had rolled back** — references, recreated memories, and the day's decision/philosophy memories — consistent with a rebuild reverting the local store to a CloudKit snapshot predating those writes. This file exists so the reasoning survives independently of the store until the sync/rebuild data-loss is diagnosed and fixed.*
