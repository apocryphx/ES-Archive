# CloudKit Throttle and Sync Triggers — what the CloudKit-Test app showed

**Status:** Findings, measured. Recommendations at the end are proposals, not
implemented.
**Audience:** Anyone touching `ESCoreDataStack`, bulk import, or sync
diagnostics. Read section 3 before concluding that sync is "stuck".
**Source:** the `CloudKit-Test` project
(`github.com/apocryphx/CloudKit-Test`, private), a one-entity macOS app built
on September 9, 2026 to reproduce the ES Archive sync stall outside the
archive's own code. Its README carries every table below plus the tooling.
**Archive records:** *CloudKit sync stall reproduced in CloudKit-Test* and
*NSPersistentCloudKitContainer trigger chain, traced with lldb* (both
September 9, 2026), and Kolja's summary entry *Working model of CloudKit sync*.

---

## 1. The question

On September 8 and 9 both ES Archive stores showed the same picture: over
100,000 records flagged as needing upload, exports failing with
`CKErrorDomain` codes 6 and 7, imports failing with `NSCocoaErrorDomain`
134421, and no successful export since September 7. The question was whether
the persistent store configuration in `ESCoreDataStack` was wrong, or whether
the behaviour was inherent to `NSPersistentCloudKitContainer` under load.

**Answer:** inherent. A store with one entity, one string attribute and the
same four settings as `ESCoreDataStack` (history tracking, remote change
notifications, automatic merge, property-object-trump policy) reproduced the
stall with a single bulk insert. Configuration was never the problem.

## 2. Method, briefly

The test app logs every container event (setup, import, export) with duration
and error to a file, reads the mirroring delegate's own bookkeeping tables
(`ANSCKRECORDMETADATA`, `ANSCKEVENT`, `ANSCKRECORDZONEMETADATA`) straight
from the SQLite file, and is driven from a shell through a command file so
batches can be inserted, deleted, and the app nudged without touching the UI.
A second target with a different bundle ID ran beside it against the same
container to observe push. lldb was attached to trace the private
`NSCloudKitMirroringDelegate` methods.

## 3. Findings

### 3.1 The server throttles by record count, not bytes

| Records in one burst | Payload | Outcome |
|---|---|---|
| 10,000 | 30 MB | exported in 67 s, no error |
| 50,000 | 150 MB | failed after 158 s and ~21,000 records, `CKError 6` |
| 62,553 deletes | ~0 | failed after 946 s and 21,600 records, `CKError 6` |

The same threshold for 3 KB inserts and for payload-free deletes: roughly
21,000 records, about 54 operations of 400. Core Data's stderr log
(`-com.apple.CoreData.CloudKitDebug 3 -com.apple.CoreData.Logging.stderr 1`)
names the cause: `Operation throttled by previous server http 429 reply.
Retry after 5.1 seconds.` The container event's `error.userInfo` is empty,
so the retry-after is invisible through the public API.

Deletes are also about seven times slower than inserts on the server side
(18 to 27 per second versus 137 to 160) and cost the same quota.
`NSBatchDeleteRequest` is only faster locally (0.28 s versus 20 s for 62k);
the mirroring delegate picks it up from persistent history and exports it as
the same 400-record operations. There is no bulk delete on CloudKit short of
deleting the record zone.

### 3.2 A paced load never triggers it

2,000 records every two minutes, about 17 records/s, reached 36,000 records
with zero pending and no retry-after, while a second app imported each batch
by push. The refill rate is therefore at least 17 records/s; where it breaks
between that and a single burst is untested.

### 3.3 After a 429 the container backs off, then recovers on its own

The symptom sequence is always: one export fails with code 6, then a burst of
code 7 failures of 0.03 to 0.1 s each, then silence. Observed silences before
the next attempt ranged from a few minutes to 89 minutes. In every case the
backlog drained without intervention once the quota had refilled: 20,001
records in 169 s after the 89-minute wait; 12,400 records in 43 minutes of
unattended retries in the evening. A second app that was never activated
caught up entirely by push.

Exports are scheduled as CloudKit scheduler activities
(`CKSchedulerActivity`, identifier
`com.apple.coredata.cloudkit.activity.export.<uuid>`, priority 2), so the
length of the wait is that scheduler's decision, not a fixed timer in Core
Data. The 89-minute case is not yet explained; power or network state of the
Mac at the time is the leading suspect.

### 3.4 App activation is a sync trigger, and it can be synthesized

`NSCloudKitMirroringDelegate` observes the four AppKit activation
notifications (`NSApplicationWill/DidBecomeActive`,
`NSApplicationWill/DidResignActive`, object `NSApp`) through
`PFCloudKitThrottledNotificationObserver`, and on becoming active schedules an
automated import and export. Ninety seconds in the background produced no
events; activation produced `CK import started` within one second, every time.

Posting the two become-active notifications from the app's own code, with
the app in the background and another app frontmost, did the same thing.
Tested against a real throttle: after four minutes of silence with 14,000
pending, the synthesized notification produced an import 1.4 s later and an
export that moved 1,600 records before the server said 429 again. So the
nudge restarts the client's scheduling exactly like a relaunch; it cannot
restore the server's quota.

### 3.5 Push works, intermittently

Between two apps on one container, a record saved on one side reached the
other in 4 to 38 s across most runs, with one first-delivery of 223 s and one
eight-minute gap with no pushes at all. When a push arrives, every device
imports, including the sender. `ZHASSUBSCRIPTIONNUM` in the zone metadata
stayed 0 throughout and says nothing about push registration.

### 3.6 Smaller facts worth keeping

- `NSCocoaErrorDomain` 134419 on an export, failing in 0.00 s with empty
  userInfo and followed at once by successful exports, is an internal
  superseded-export case and harmless. It appears twice per ES Archive store.
- A bundle ID that automatic provisioning merely registers can sign with the
  container entitlement and still be refused at setup with `CKError 2` wrapping
  `Permission Failure 10/2007 "Invalid bundle ID for container"`. The App ID
  must be granted the container, which building the target through Xcode does.
- Deleting records in the CloudKit console removed about 800 of 35,000; a
  fresh local store re-imported the rest. Only a zone delete
  (`CKModifyRecordZonesOperation`) or an environment reset clears a container
  in one request, and the local store must be deleted at the same time or the
  container re-exports everything it holds.
- `zsh` has a builtin named `log`; use `/usr/bin/log` to read the unified log
  from a script.

## 4. What this means for ES Archive

### 4.1 Diagnosis of the September 8 state

The two stores are not stuck, they are throttled with a backlog far larger
than one burst, and they share one container and therefore one quota. At the
measured drain rates, over 100,000 pending per store is many hours of
undisturbed running. Repeated relaunches (each Claude Desktop session
launches `ES Archive MCP`) restart the client and burn the refilled quota in
small bites, which does not help and may prolong the throttle.

### 4.2 Proposed decisions

1. **Pace bulk loads.** Chunks of about 2,000 with a two-minute gap are
   known safe, roughly 60,000 records per hour. Anything that inserts or
   deletes tens of thousands of entries at once (AppleDoc loads, tag purges,
   migrations) should go through a pacer, or be done with mirroring disabled
   and the store treated as a separate persona outside CloudKit.
2. **Watch pending counts, not events.** `sum(ZNEEDSUPLOAD)` and
   `sum(ZNEEDSCLOUDDELETE)` in `ANSCKRECORDMETADATA` are the truth. A quiet
   log after a code-6 failure is backoff, not death. System Pulse could show
   these two numbers and the last export error code.
3. **Leave a throttled store running.** Do not relaunch to "kick" it; the
   kick works but costs quota. If a nudge is wanted, post the activation
   notifications instead of relaunching; both targets have `NSApplication`,
   so the observer is installed.
4. **One mirroring store per container.** If `ES Archive MCP` and
   `ES Archive Server` both keep their own store, they halve each other's
   throughput and double the export volume. Whichever process is not the
   primary writer should not mirror.
5. **Fix `resetPersistentContainer`.** It re-adds the store with
   `options:nil` outside the container, so after a reset the store has no
   history tracking and no mirroring until relaunch.
6. **Set the merge policy before load, not in an async block.** There is a
   window on first access where the view context still has the default
   error-on-conflict policy.
7. **Debug builds now carry the push entitlement**
   (`com.apple.developer.aps-environment = development`, added September 9),
   so Debug behaviour matches Release: imports arrive by push rather than only
   at launch and after saves.

## 5. Open questions

- The sustainable rate between 17 records/s and a single 21,000 burst.
- Why one backoff lasted 89 minutes and others a few minutes.
- Whether large payloads (embeddings) change operation size or the burst
  limit; the test app has a payload attribute ready for this.
- Whether the throttle is per container, per account, or per device. A new
  container started with no throttle state, which suggests per container.
