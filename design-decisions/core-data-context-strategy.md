# Core Data Context Strategy — background contexts yes, batch requests no

**Status:** Conclusions from the September 9, 2026 CloudKit investigation,
answering two questions Kolja asked afterwards. Proposals, not implemented.
**Audience:** Anyone adding bulk import, bulk delete, or migration code to
ES Archive, or changing how tool calls reach Core Data.
**Companion:** `cloudkit-throttle-and-sync-triggers.md` in this folder, which
holds the measurements this brief leans on.

---

## 1. The two questions

1. Is there any advantage in running Core Data operations on a background
   context?
2. Is there any need to use the batch requests (`NSBatchInsertRequest`,
   `NSBatchUpdateRequest`, `NSBatchDeleteRequest`)?

Short answers: **yes, for bulk work and for a server process**, and **no**.

## 2. What neither choice changes

Nothing about CloudKit. The mirroring delegate exports and imports on its own
private contexts and queues, slices exports into operations of 400 records,
and is throttled by the server at roughly 21,000 records per burst whatever
the origin of the saves. A background context and a batch request produce the
same operations, the same quota consumption, and the same backoff. The only
lever on CloudKit throughput is pacing: about 2,000 records every two minutes
is known safe (`cloudkit-throttle-and-sync-triggers.md`, section 3.2).

## 3. Background contexts: the advantages, ranked for ES Archive

1. **Memory during bulk work.** Objects inserted or fetched into a context
   stay registered until the context is reset. The CloudKit-Test delete loop
   materialised 62,553 objects in the view context and took 20 s; ES Archive
   has already seen about 140 KB per entry retained under bulk import through
   the view context's undo manager. A background context working in batches
   of a few thousand, with a save and a reset per batch, hands the memory
   back each time. That batch shape is also exactly what the pacing needs.
2. **Not blocking the main queue.** Both ES Archive targets funnel every
   Core Data operation through the main thread via `ExecuteOnMainThread`.
   That is correct but coarse: one long tool call stalls every other tool,
   the run loop, timers, and the activation observer the mirroring delegate
   depends on for its foreground trigger. A private-queue context serialises
   just as strictly within itself and leaves main free. For a server process
   this matters more than for a document app.
3. **Cheaper merges after imports.** With `automaticallyMergesChangesFromParent`
   on, every record the delegate imports is merged into the view context on
   the main thread, at a cost that scales with how many objects the view
   context has registered. Keeping the view context lean keeps a 35,000-record
   import from being felt.

Costs are the usual ones: objects do not cross contexts (pass
`NSManagedObjectID`), both contexts need the same merge policy, and any
fetched results controller stays on the view context. Using the container's
`performBackgroundTask:` or `newBackgroundContext` gives a context whose
saves merge into the view context automatically, so the plumbing is small.

## 4. Batch requests: why not

What they buy is local speed and memory, because they skip object creation:
`NSBatchDeleteRequest` removed 5,000 records in 0.28 s where a context loop
takes about 2 s, and the export still happened because persistent history
records batch operations. For a large relationship-free table that is real.

Why they do not fit ES Archive:

- **They bypass the object graph.** Batch delete does not run delete rules,
  so a cascade from an entry to its links, comments and tag memberships would
  not happen; orphans and dangling references would remain. Batch insert
  cannot set relationships at all, and every archive entry has them.
- **They bypass the context.** No validation, no `willSave`/`didSave`, no
  context-did-save notification. The caller merges the returned object IDs
  into the view context by hand, and anything else observing the context
  misses the change entirely. The test app needed that manual merge just to
  refresh a table.

The one place a batch request still makes sense: deleting a large,
relationship-free set such as a cache table, where the sub-second local
delete is the whole point.

## 5. Proposed practice

- **Bulk import, bulk delete, migrations:** a background context, batches of
  about 2,000, save and reset per batch, a two-minute pause between batches
  while CloudKit mirroring is enabled. Delete through the context so delete
  rules apply.
- **Interactive tool calls:** leave them on the current main-thread funnel;
  they are short and the funnel keeps them consistent.
- **Batch requests:** only for relationship-free tables, and only when the
  local speed matters.
- **The view context:** reads and UI only. No undo manager (already the
  case), and no bulk work through it.

## 6. What this does not settle

Whether the tool-call funnel itself should move off the main thread is a
separate question with its own trade-offs (ordering guarantees between tools,
the socket election, System Pulse updates). This brief only argues that bulk
work should not be on it.
