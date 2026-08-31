# The Archive Vocabulary: ES Memory Becomes ES Archive

**Date:** August 30, 2026
**Status:** Executed (clean cut, no aliases)

## Why

Three arguments, in ascending order of weight:

1. **Descriptive accuracy.** The system is an archive in how it is written to: deliberate access, curated writing, multiple authors with provenance, references, revisions, locked entries. The prose layer had already drifted to "archive" organically (the README, the discover tool's description, the skills) before the rename was decided. The rename ratified existing usage rather than imposing new usage.

2. **Third-party crowding.** "Memory" is the most collided concept in the MCP ecosystem: the Anthropic reference server is literally named `memory`, and mem0/OpenMemory and many others ship `memory`-shaped tools. "Archive" collides too (Internet Archive tooling, file-archive tools, archive.com), but with different meanings rather than direct competitors.

3. **First-party capture (the decisive argument).** Anthropic's built-in memory feature is named simply "memory" and works across chat, Cowork, desktop, and mobile. In any Claude context, the word now defaults to the platform feature. A third-party product named "ES Memory" reads as a redundant wrapper about to be obsoleted; "ES Archive" positions the product as complementary: Claude's memory is automatic and ambient, the Archive is deliberate, curated, and provenance-tracked. The name survives the platform feature improving.

"Memory" remains the category descriptor ("persistent memory for Claude"); "Archive" is the product identity. The category word can be shared with the platform; the product name cannot.

## Two registers

The PUBLIC register appears in product names, tool names, tool descriptions, README, App Store. The INTERNAL register may season skill files and session-facing prose, sparingly.

Public register:

| Old term | New term | Notes |
|---|---|---|
| ES Memory (the system) | ES Archive | Product identity. |
| the store / the system | the Archive | The collection itself, capitalized. |
| a memory (stored item) | entry | Technical prose and parameter docs. |
| memory_* tools | archive_* tools | Renamed in one cut, no aliases. |
| memory_cli | archive_cli | Internal Unix command names (w2vgrep, lfind, discover…) unchanged. |
| memory_title parameter | entry_title | The one parameter rename. |
| Memory Scope | Archive Scope | The graph visualizer. |
| .esmemory backup extension | .esarchive | Old files can be renamed by hand; the UTI identifier did not change. |

Internal register (skills and session-facing prose only, never in tool names, parameter names, schema, or marketing):

| Concept | Internal term |
|---|---|
| a session using the tools | the scriptorium / a scribe |
| the fixed store procedure | the liturgy (the couplets in es-archive-store) |
| comment | marginalia |

Further internal vocabulary (folio, incipit, colophon, rubric) is available to session prose but is deliberately not baked into the skill files; the dosage rule is that vocabulary appears as terminology, not as ceremony.

## What did NOT change (and must not)

These are identity-bearing. The rename is names and text only.

1. **CloudKit / Core Data schema.** CDMemory, CDVector, tag entities, all Core Data class names, and every attribute. The production schema is effectively immutable; the synced store predates the rename.
2. **Stored data.** Five months of corpus stays as written; the corpus is bilingual and that is accepted. `type=memory` stays as a stored type value (one kind of entry among eleven: the kind that records what happened).
3. **Bundle identifiers, App Group** (`group.com.elarity.esmemory`), **UDS socket path, port 59123**, the `.mcpb` manifest slug (`es-memory-bridge`), the log subsystem (`com.elarity.es-memory-mcp`), the backup UTI (`com.elarity.es-memory.backup`), dispatch queue names, and the UDS handshake method (`$/esmemory/author`). Identity strings upgrade installs in place; labels do not.
4. **The .app product names and every path containing them** (`/Applications/ES Memory MCP.app/...`). The connector manifest launches the binary by path; the new identity is carried by `CFBundleDisplayName` instead.
5. **Objective-C class names** (ESMemoryStoreTool and friends). Not user-visible; churn there is pure risk.
6. **`ESMB_NO_AUTOLAUNCH`** and other documented configuration knobs.
7. **archive_cli internal command names** (w2vgrep, grep, lfind, discover, tag, untag, head, sort, wc, cat, man). Unix vocabulary, not memory vocabulary.

## Why a clean cut instead of aliases

The original migration brief mandated `memory_*` aliases for a deprecation period. That assumed consumers that cannot be enumerated. In fact every consumer is either self-healing or under the author's control: models re-read the tool listing and descriptions fresh each session, the app ships no bundled skills, and there are no external users. Under those conditions aliases are not a safety net; they are live old wires that let a broken new circuit carry traffic anyway, and they contaminate cold-session testing of the rewritten skills. A missed reference under the clean cut fails loudly (tool not found), which enumerates the remaining stale wires the way a compiler enumerates call sites after a rename.

Corollary: any text that instructs a session to fail silently when the tools are absent must be updated *before* the cut, or the rename is indistinguishable from a decommissioned server.

## Trigger vocabulary is not renamed

Users say "remember this", "do you remember", "the memory about X". The skill trigger descriptions retain those phrases, and every skill carries a glossary line binding the vocabulary to the grammar ("an entry is what archive_store creates"). Skills fire on what users actually say.
