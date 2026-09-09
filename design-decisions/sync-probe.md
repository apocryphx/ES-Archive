# ES Sync Probe — observing and driving CloudKit + Core Data at bulk scale

**Status:** Design brief, ready to implement. Nothing implemented yet.
**Audience:** A fresh coding session. Read this whole document first. Code
locations are exact as of `main` at `1c629c9` (September 8, 2026).
**Archive record:** *Sync probe: a test app to observe and drive CloudKit and
Core Data behavior (proposal, September 8, 2026)*, and the findings it must
reproduce in *AppleDoc persona: the Apple docs archive as an ES Archive scale
test (September 7, 2026)* and *ES Archive stress test: CloudKit export pins the
SQLite WAL checkpoint (September 7, 2026)*.

---

## 1. Why

On September 7–8 the AppleDoc load (68,523 entries) and its deletion exposed
four sync failures, every one of them diagnosed from *outside* the process:
read-only SQLite counts every 30 s, the WAL-index header parsed from the `-shm`
file, `sample` on the running app, and console pastes from Debug builds.

| Failure | How it showed | Root cause |
|---|---|---|
| Exporter pins the WAL | write rate halved every 25 min; `walFindFrame` 60% of request time; log to 8 GB | exporter's read transaction stays open while its upload backlog drains |
| Receiver never imports | inserts took ~2 days to reach the second store; deletes not at all for 3 h | `Giving up waiting to register for remote notifications` — no push, imports only at launch |
| Token-expired reset | `Change Token Expired: client knowledge differs from server knowledge` → full zone re-fetch, 2.36 GB WAL pin, then a re-upload storm throttled by HTTP 429 / 503 / "deferred by the system" | one device churned through more changes than a change token covers |
| Resurrection after bulk delete | server back to 6,483 deleted rows, receiver to 2,852; three deletes needed | stale device's reset resync re-uploads what it still holds |

The probe makes those observations first-class and the scenarios repeatable,
against a container that can never touch the production archive.

## 2. Non-negotiables

- **Same schema, same classes.** The probe links `ES_Archive/Core Data Schema/`
  (the `Electric_Sheep.xcdatamodeld` with versions `Electric_Sheep` and
  `Electric_Sheep_1_1`, and `CDMemory`, `CDMemoryRevision`, `CDVector`,
  `CDEmbedder`, `CDTag`, `CDLink`, `CDMarginalia`, `CDReference`,
  `CDMemoryLookup`). What it measures is the real model, not a stand-in.
- **Its own CloudKit container.** `iCloud.com.elarity.es-archive-probe`, in the
  **development** environment. Never `iCloud.com.elarity.electric-sheep`. The
  probe's entitlements list only its own container.
- **Its own bundle id and sandbox container**, so its store files, defaults and
  logs are separate: `com.elarity.es-sync-probe`.
- **Push entitlement.** `aps-environment` (development) so the probe can test
  push-driven import. Note: the shipping apps' `ES_Archive.entitlements` has
  the iCloud container but **no `aps-environment`** — that is the likely reason
  for "Giving up waiting to register for remote notifications", and the probe's
  first job is to prove it (§6, S5).
- **Samples from the Apple docs archive.** Bulk entries are built from
  `/Volumes/AppleDocsArchive/raw-json/<framework>/**.json` exactly as the
  September loader did (see §4), so sizes are known and content is realistic
  (68,523 unique symbols with abstracts across 49 frameworks; Accelerate ≈ 5,600,
  App Intents ≈ 2,500, Foundation ≈ 10,900, Swift ≈ 15,400).

## 3. What to adopt from ES_Archive, and what not

Adopt by target membership (synchronized-folder exceptions, as the two apps do):

| Adopt | Why |
|---|---|
| `Core Data Schema/*` | the model and its classes |
| `CoreData/ESCoreDataStack.{h,m}` | the container setup — **parametrize** it: store URL, configuration list, CloudKit container id (or nil for local-only), so one code path serves production and probe |
| `CoreData/ESDeduplicator*`, `ESDedupeMergeCore*`, `ESUUIDStampedObject*` | a subject under test; must be switchable off per scenario |
| `VectorEngine/*`, `Embedders/*` | real vectors (EmbeddingGemma, 768-d) so `CDVector` traffic is realistic |
| `Persistence/ESBackupArchive*`, `ESBackupManager*` | the restore path is the bulk-import candidate (§6, S7) |
| `ESLog.h` | logging |

Do **not** adopt: `Server/` (HTTP, tools, pipeline), `Stdio/`, `MemoryScope/`,
`SystemPulse/`, `Settings/`. The probe has its own window.

`ESCoreDataStack` today hard-codes `initWithName:@"Electric_Sheep"` and takes the
first store description. The minimal change: an initializer that accepts an
array of `NSPersistentStoreDescription` (URL, configuration name,
`cloudKitContainerOptions` or nil) and keeps today's behavior as the default.
This is also the change the vectors-local-only design needs (§6, S6), so make it
once.

## 4. Sample source: the Apple docs archive

Port the September loader's mapping (`appledoc_ingest.py`, in the stress-test
session's scratchpad; the rules are restated here so nothing depends on it):

- Walk `raw-json/<framework>/`, keep one file per case-folded path, preferring
  the natural-cased twin.
- Skip pages without an `abstract`.
- Title: symbol path from the doc `identifier.url` after `/documentation/<Module>/`,
  joined by `.`, then ` (<roleHeading>, <module>)`, e.g.
  `UIView.frame (Instance Property, UIKit)`.
- Summary: `<display> is a <role> in <module>. <abstract> Available on <platforms with introduced versions>.`
  plus a deprecation sentence when present.
- Body: title line, Swift/ObjC declaration in a code fence, abstract, platforms,
  `Doc: https://developer.apple.com/documentation/<path>`.
- Type `reference`, language `en`, one tag per module (kind `thing`),
  author = the scenario's persona (e.g. `ProbeDoc`).
- Optional `CDReference` of type `path` to `markdown/<path>.md`.

Expose it as `ESProbeSampleSource` with `-entriesForFramework:limit:` returning
plain value objects; the scenario writer turns them into `CDMemory` + `CDVector`.

## 5. What the probe records — one timeline, one file per run

Every row: `timestamp, instance, source, kind, detail…`. Written as CSV (and a
JSON sidecar with the run's parameters) to
`~/Library/Logs/ESSyncProbe/<run-id>/timeline.csv` inside the probe's container.
A live window shows the same rows plus counters.

1. **CloudKit events.** Observe `NSPersistentCloudKitContainerEventChangedNotification`;
   log type (setup/import/export), `startDate`, `endDate`, `succeeded`, and the
   **full** error: domain, code, `localizedDescription`, `CKErrorRetryAfterKey`,
   and every partial error (the token-expired and 429/503 cases live there).
2. **Persistent history.** After each remote-change notification, fetch
   transactions since the last token: `author`, `contextName`, `timestamp`,
   change counts by entity and change type. This is where "who wrote 37,000
   vector inserts" becomes a row.
3. **Store health**, sampled every N seconds (default 5): row counts per entity
   and per `author`; `ANSCKRECORDMETADATA`, `ANSCKEXPORTOPERATION`,
   `ANSCKIMPORTOPERATION`, `ANSCKHISTORYANALYZERSTATE` counts (pending export,
   tombstones); store file size, WAL size.
4. **WAL-index header**, same cadence, read from the store's `-shm` file:
   `mxFrame` (u32 at offset 16), `nBackfill` (u32 at 96), `aReadMark[5]` (u32 at
   100–119); `0xffffffff` = free. A read mark equal to `nBackfill` while
   `mxFrame` grows is the pinned-checkpoint signature. (Layout: two 48-byte
   `WalIndexHdr` copies, then `WalCkptInfo`.)
5. **Environment.** `CKContainer.accountStatus`, remote-notification
   registration result (`didRegisterForRemoteNotificationsWithDeviceToken` /
   `didFailToRegister…`), reachability, process RSS and CPU time.
6. **Driver events.** Every scenario step with its parameters and duration.

## 6. Scenarios (the driver)

Each scenario is a class with `run(params) → report`, runnable from the window
and from the command line (`ESSyncProbe --instance A --scenario S3 --n 20000
--out <dir>`). Two instances on one Mac (`--instance A|B`) use separate store
files under the probe's container and mirror the same probe CloudKit container;
each is a "device".

| # | Scenario | Reproduces | Pass criterion / measurement |
|---|---|---|---|
| S1 | **Sustained write** — insert N (default 20,000) sample entries with vectors at max rate | exporter WAL pin | `nBackfill` freezes while `mxFrame` grows; record onset time, WAL peak, write rate decay; then the same with the receiver-side pin fix candidates |
| S2 | **Stale device reset** — A inserts N while B is quit; relaunch B | token-expired reset, import pin, re-upload storm | log the `Change Token Expired` event, B's WAL peak during re-import, time to converge, count of 429/503 and retry-after seconds |
| S3 | **Bulk delete + resurrection** — A and B converged at N; quit B; A deletes by author; relaunch B | resurrection | rows by author on both stores over time; **fails** if either store rises after A's delete. Variant S3b: delete on both before relaunch; must stay at zero |
| S4 | **Throttling** — A and B both exporting large sets | account throttling | histogram of CKError codes and retry-after values |
| S5 | **Push** — with and without `aps-environment`; A writes one entry, measure time until B imports it | "Giving up waiting to register…" | latency with push vs. launch-only; registration success logged |
| S6 | **Vectors local-only** — model configuration `Local` for `CDVector` (no cross-store relationship; `memoryUUID` key), re-run S1–S4 | design decision | traffic and WAL compared against baseline |
| S7 | **Bulk import by restore** — build an `.esarchive` from samples, restore into an empty store, backfill vectors | import path design | restore time, backfill throughput (the embedder ceiling: serial vs batched prediction) |
| S8 | **Deduplicator cost** — S1 with the deduplicator on vs. off, and with sweeps filtered by `transactionAuthor` | 40% of request time under load | per-save cost, sweep count |

## 7. UI (minimal)

One window: a scenario picker with parameters (N, framework, instance),
Run / Cancel; a timeline table bound to the run's rows; a counters strip
(rows by author, vectors, pending exports, WAL MB, `nBackfill`/`mxFrame`,
account status, push registered); the three CloudKit dots as in System Pulse;
an Export button that reveals the run directory. No graph, no tag cloud.

## 8. Steps

1. New app target `ES Sync Probe` (bundle `com.elarity.es-sync-probe`,
   sandboxed, entitlements: its own iCloud container, `aps-environment`
   development, app group not needed). Add the folders in §3 by synchronized
   membership.
2. Parametrize `ESCoreDataStack` (§3) without changing the two apps' behavior;
   build all three targets.
3. Recorder (§5): event observer, history reader, store sampler, WAL-header
   reader, environment probe, CSV writer.
4. Sample source (§4) and the scenario driver with S1 first; then S3, S2, S5.
5. CLI entry (`--instance`, `--scenario`, `--n`, `--framework`, `--out`).
6. S6 and S7 after the model configuration change and the backup parametrization.

## 9. Acceptance

- S1 on 20,000 Accelerate+AppIntents+Foundation entries reproduces the pin
  (read mark == `nBackfill`, `mxFrame` climbing) within the first minutes, and
  the timeline shows the exporter's export events without errors.
- S3 reproduces resurrection (rows rise on A after B relaunches), and S3b
  passes (both stay at zero).
- S5 shows push-driven import latency under a few seconds with
  `aps-environment`, versus launch-only without it.
- Nothing the probe does appears in the production apps' stores or in the
  `iCloud.com.elarity.electric-sheep` container.

## 10. Non-goals

No changes to the two shipping apps beyond the `ESCoreDataStack`
parametrization. No new tools, no HTTP, no MCP. No UI polish.
