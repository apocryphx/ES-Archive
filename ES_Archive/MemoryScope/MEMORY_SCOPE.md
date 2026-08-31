# Archive Scope — Design & Architecture

Force-directed graph visualization of the ES Archive.
Renders entries as interactive nodes connected by weighted edges, with
real-time delta updates from Core Data and access animations from MCP tools.

## Personas

The scope is persona-aware. A picker in the status bar selects which mind to
view:

- **One persona** (default: the primary persona): the memory FRC is scoped
  `author == <persona>`, and similarity is computed only within that persona's
  own vectors (via `similarToMemory:limit:allowedVectorIDs:`). This is the
  boundary each persona actually experiences — no cross-persona edges. Nodes
  are colored by **heat** (access frequency).
- **All (witness)**: every persona's entries together, similarity unscoped so
  cross-persona edges appear. Nodes are colored by **persona** (a stable
  name-hashed palette). The human's witness-only overview of the whole archive.

The picker lists every distinct author in the archive (including unbound
personas with records but no port), fetched from CDMemory.

---

## Architecture

```
CDMemory + CDLink (Core Data)
       ↓
  [FRCs: memory, link]
       ↓
  ESMemoryScopeDataSource  →  ESGraphDeltaBatch
       ↓
  ESForceGraph (nodes + edges + physics)
       ↓
  ESMemoryScopeView (Core Graphics + gesture recognizers)
       ↓
  ESMemoryScopeWindowController (tabs + detail panel + status bar)

[MCP Tools] → ESMemoryToolBase → ESMemoryAccessNotification → flash animations
```

Seven files, 14 .h/.m pairs:

| File | Role |
|------|------|
| ESForceGraph | Physics engine: nodes, edges, repulsion, springs, settling |
| ESMemoryScopeDataSource | Core Data bridge, FRC delegates, delta batch processing |
| ESMemoryScopeView | Core Graphics renderer, gesture recognizers, animation handlers |
| ESMemoryScopeWindowController | NSTabViewController (graph + tag cloud), detail panel, status bar |
| ESColorLUT | 256-entry color lookup tables (hot-cold, thermal, ocean, grayscale) |
| ESTagCloudView | Archimedean spiral tag layout with its own FRC |
| ESMemoryNotifications | Access notification constants and type enum |

---

## Force Simulation

### Physics Model

Each tick (60 Hz) while `alpha >= 0.001`:

1. **All-pairs repulsion** — Coulomb-like: `force = alpha * 500 / dist²`, cutoff at 300 units
2. **Spring attraction** — Hooke's law along edges: `force = alpha * 0.02 * displacement`
   - CDLink rest length: 60 (tight clusters)
   - Similarity rest length: 120 (loose association)
3. **Center gravity** — Weak pull toward centroid: `0.01 * alpha`
4. **Damping** — Velocity *= 0.9 each frame, clamped to max 15
5. **Alpha decay** — `alpha *= 0.995` (energy drains over ~700 frames)
6. **Flash decay** — `flashIntensity *= 0.88` (~18 frames to fade, runs even after physics settles)

**Note:** Spring force does NOT use `edge.weight`. All similarity edges pull
identically — layout is purely topological. Edge weight only affects visual
alpha in the renderer.

### Settlement

Simulation stops when: `alpha < 0.001 AND maxPositionDelta < 0.1 AND all flashIntensity < 0.01`

Restarted by: delta batch mutations, access notifications, or user interaction.

---

## Graph Construction

### Cold Build (buildGraph)

Triggered on window show, manual refresh, or delta batch > 20 changes.

1. Fetch the selected persona's CDMemory (excludes revisions) and CDLink;
   compute the allowed vector-ID set for within-persona similarity (nil in
   All mode)
2. Compute heat: `node.heat = accessCount / maxAccessCount` (normalized [0,1])
3. **Seeds** (nodes with CDLinks): random positions in center 50% of canvas
4. **Satellites** (no CDLinks): positioned at nearest visible neighbor via vector search
5. Add CDLink edges (weight=1.0, isExplicitLink=YES) — explicit, unlimited
6. Add **one** similarity edge per memory — to its single nearest neighbor
   (persona-scoped). No dedup, no eviction: a memory contributes exactly one
   outgoing edge; many-incoming is natural hub structure.
7. **Bridge islands** (`bridgeIslandsToGiantWithEngine:context:`) — one edge per
   memory is a functional graph that fragments into a giant component plus small
   islands; add one bridge edge from each island to the giant so the graph is
   one connected whole (see [Graph Connectivity](#graph-connectivity))
8. Set alpha=1.0, post ESGraphDidUpdateNotification

### Delta Updates (processDeltaBatch)

For ≤20 changes, applied incrementally (order matters):

1. **Memory deletes** — Remove node + all touching edges. Deleting a memory
   strips the one similarity edge a neighbor had pointing *at* it, so every
   now-edgeless node is re-given a nearest-neighbor edge (orphan heal), then
   `bridgeIslandsToGiantWithEngine:context:` runs again — a re-picked neighbor
   can land a healed node in an island, so we re-bridge. Idempotent: a no-op
   when the graph is already one connected whole.
2. **Memory inserts** — Create node at its nearest neighbor and add that single
   similarity edge (persona-scoped). No dedup, no eviction.
3. **Memory updates** — Sync title + heat, no position change
4. **CDLink inserts** — Add the explicit edge (similarity edges are independent;
   not removed)
5. **CDLink deletes** — Reconcile: scan explicit edges, remove any without backing CDLink

Alpha nudges restart physics: insert=0.4, delete=0.15, link change=0.2.

---

## Graph Connectivity

One similarity edge per memory builds a **functional graph** (out-degree exactly
1). Two facts follow:

- **A degree-0 node is impossible.** Every memory emits one edge, so every node
  has degree ≥ 1. The only exception is a memory with **no vector** — it emits no
  edge and genuinely floats alone, which is a signal that an embedding is
  missing, not a graph bug.
- **The graph fragments.** Nearest-neighbor pointers close on
  mutual-nearest-neighbor pairs, so clusters whose members are all one another's
  nearest neighbor — and which nothing outside points into — detach as
  **islands**. The minimum island is a *pair*, never a singleton. Left alone,
  ~15% of nodes land in islands (e.g. Claude: giant 652 + 35 islands = 770).

`bridgeIslandsToGiantWithEngine:context:` repairs this: it finds the connected
components (undirected DFS), takes the largest as the **giant**, and adds one
bridge edge from each remaining component to the giant — the island member whose
nearest giant node scores highest (search scoped to giant vector IDs so islands
attach to the giant, never to each other). ~one bridge edge per island; the
one-edge-per-memory core is untouched. Idempotent — a connected graph has a
single component and returns before any similarity search, so it runs safely
from both the cold build and the delta heal.

The **`Isolated:`** status counter counts degree-0 nodes. On a bridged graph it
reads 0 (correct), and because degree-0 is structurally impossible it only ever
flags the no-vector exception above — not islands. See
[`design-decisions/graph-island-bridging.md`](../../design-decisions/graph-island-bridging.md)
for the full rationale and the alternatives weighed.

---

## Rendering

### Drawing Cache

Rebuilt every tick. All coordinates pre-transformed to view space.

**Edges:**
- CDLink: 2px stroke, separator color at alpha 0.8
- Similarity: 0.5px stroke, alpha normalized to strongest edge then sqrt-spread:
  ```
  alpha = sqrt(edge.weight / maxSimilarityWeight)
  ```
  No magic floor — adapts to whatever score range the engine produces.

**Nodes:**
- Oval radius: `6 * viewScale`, clamped [3, 12]
- Color from ESColorLUT based on `node.heat`
- Flash: blend toward white by `node.flashIntensity`

**Selection:** Ring around selected node (controlAccentColor, 2px stroke)

### Transform

- `viewScale` — zoom level [0.1, 50.0]
- `viewOffset` — pan translation
- `hasUserTransform` — when NO, auto-fits graph to view bounds
- Auto-fit: compute scale from bounding rect with 40px padding, cap at 3x

---

## Interaction

### Gesture Recognizers

| Gesture | Action |
|---------|--------|
| Pan (drag) | Translate viewOffset |
| Magnify (pinch) | Zoom centered on cursor |
| Scroll wheel | Zoom centered on cursor (trackpad: smooth, mouse: discrete) |
| Single click | Select node / deselect (non-toggle) |
| Double click on node | Animate center on node |
| Double click on empty | Reset to auto-fit |
| Mouse move | Hover popover showing node title |

**No failure requirements** between single and double-click recognizers.
Single-click fires immediately on every click (including the two clicks that
compose a double-click). This is harmless because selection uses non-toggle
logic: click node = select, click empty = deselect. The double-click handler
fires after both single-clicks, and its action (centering) doesn't conflict.

### Centering Animation

- Duration: 0.7 seconds
- Easing: cubic ease-out `1 - (1-t)³`
- Double-click on empty: animate to auto-fit, then drop `hasUserTransform`
- Double-click on node: slide offset to center node, keep current zoom

---

## Access Animations

MCP tools post `ESMemoryAccessNotification` via `ESMemoryToolBase`. The view
observes this notification and triggers type-specific animation patterns.

### Six Patterns

| Type | Intensity | Delay | Effect |
|------|-----------|-------|--------|
| **Read** | 1.0 | 0 | Single node pulse |
| **Search** | score | i * 80ms | Cascade by relevance |
| **Discover** | score | i * 180ms | Slow dramatic reveal |
| **Recent** | 0.75 | i * 120ms | Uniform sequential |
| **Tagged** | 0.8 | 0 | All simultaneous |
| **Links** | origin=1.0, neighbors=0.65 | origin=0, neighbors=0.1+i*70ms | Hub ripple |

**Flash stacking:** `node.flashIntensity = max(current, new)` — multiple
concurrent animations blend gracefully.

**Flash decay:** `intensity *= 0.88` each tick. At 60fps, a flash at 1.0
fades below visibility (0.01) in ~18 frames (~300ms).

### Notification Payload

```objc
@{
    ESMemoryAccessTypeKey:      @(ESMemoryAccessType),
    ESMemoryAccessObjectIDsKey: @[NSManagedObjectID, ...],
    ESMemoryAccessScoresKey:    @[@(float), ...],      // optional
    ESMemoryAccessOriginIDKey:  NSManagedObjectID       // optional (links only)
}
```

Posted by ESMemoryToolBase from MCP tool execution context, dispatched to
main queue before NSNotificationCenter post.

---

## Scoring Formula

Similarity search results are weighted by a sigmoid recency curve
("Sheep Hill Curve"). Full documentation is in the comment block above
`weightedScore:forEntry:` in ESVectorEngine.m. Summary:

```
score = cosine * sigmoid(daysSinceLastAccess)
```

where `sigmoid = floor + (1-floor) / (1 + exp(k * (t - mid)))`,
`k = d * slope`, `mid = max(0, 10/d + shift)`, `floor = 0.20`.

**Key design decisions:**

1. **Sigmoid, not power-law or exponential.** The sigmoid gives a grace
   period (shoulder) where recent entries stay at full strength, a smooth
   transition zone, and a 0.20 floor where old entries settle but never
   vanish. The only curve that models temporal horizons cleanly.

2. **lastAccessed, not dateCreated.** A 365-day-old memory accessed yesterday
   should score high. Falls back to creationTimestamp if never accessed.

3. **Frequency boost removed (March 9, 2026).** `log1p(accessCount)` created
   feedback loops — accessed entries surfaced more, became universal hubs.
   The Einstellung effect as math.

4. **Sentiment scoring removed (April 8, 2026).** NLTagger's classifier
   collapsed to a near-constant on the corpus (probe: five distinct summaries
   all returned -0.6). Signal was noise; the one mode that depended on it
   (`traumatic`) was already structurally broken.

5. **d=0 returns pure cosine** — the unfiltered semantic landscape.

Default: `decayLevel = "none"` (pure cosine).

---

## Tag Cloud

Alternative tab using Archimedean spiral layout.

- Own FRC on CDTag entity, sorted by memory count descending
- Font size: `11 + log(count)/log(maxCount) * 41` (range 11–52pt)
- Font weight: top half bold, bottom half regular
- 10-color palette indexed by `hash(tag.kind) % 10`
- Spiral: `radius = 3 + 0.4 * angle`, step angle 0.3 radians, max 2000 iterations
- Collision detection: CGRectIntersectsRect against all placed items
- Background thread computation, generation-tagged to drop stale layouts
- Click: popover with tag name, kind, memory count

---

## Color LUT

256-entry lookup table mapping heat [0,1] to NSColor. One preset:

- **Hot-Cold:** blue → cyan → green → yellow → red

Linear interpolation between control points. Both NSColor and CGColorRef
cached for rendering performance. (Used only in single-persona mode; All
mode colors by persona via the view's name-hashed palette.)

---

## Window Layout

```
┌────────────────────────────────────────┐
│ [Archive Scope | Tag Cloud]             │  ← Segmented tab control
│ ┌──────────────────────┬─────────────┐ │
│ │                      │ Detail      │ │  ← Slides in from right (280px)
│ │  Graph / Tag Cloud   │ Panel       │ │     Glass effect background
│ │                      │             │ │     Title, metadata, body
│ │                      │             │ │
│ └──────────────────────┴─────────────┘ │
│ Nodes: 280/280  Links: 147  Sim: 820   │  ← Status bar (28px, monospace)
└────────────────────────────────────────┘
```

Detail panel animates open on node selection, closes on deselect or tab switch.
Status bar updates every 0.5s: node count, link count, similarity edge count,
simulation state (Settled / Simulating...).

---

## Constants Reference

| Constant | Value | Context |
|----------|-------|---------|
| kRepulsionStrength | 500 | Force magnitude |
| kRepulsionMaxDist | 300 | Repulsion cutoff (units) |
| kSpringStrength | 0.02 | Spring constant |
| kLinkRestLength | 60 | CDLink edge rest distance |
| kSimilarityRestLength | 120 | Similarity edge rest distance |
| kCenterGravity | 0.01 | Center-of-mass pull |
| kDamping | 0.9 | Velocity decay per tick |
| kAlphaDecay | 0.995 | Energy decay per tick |
| kAlphaMin | 0.001 | Physics stop threshold |
| kSettleDelta | 0.1 | Position delta for settled |
| kMaxVelocity | 15 | Velocity clamp |
| kFlashDecay | 0.88 | Flash fade rate (~18 frames) |
| kNodeRadius | 6 | Base node radius (scaled, clamped [3,12]) |
| kEdgeStrokeWidth | 2 | CDLink edge width |
| kDeltaFallbackThreshold | 20 | Full rebuild trigger |
| kAlphaNudgeInsert | 0.4 | Physics restart on insert |
| kAlphaNudgeDelete | 0.15 | Physics restart on delete |
| kAlphaNudgeLinkChange | 0.2 | Physics restart on link change |
| kZoomMin / kZoomMax | 0.1 / 50 | Zoom range |
| kScrollZoomSpeed | 0.05 | Mouse wheel zoom per tick |
| kCenteringDuration | 0.7 | Center animation (seconds) |
| kDetailPanelWidth | 280 | Detail panel width |
| kMinFontSize / kMaxFontSize | 11 / 52 | Tag cloud font range |
| kSpiralStep / kSpiralGrowth | 3 / 0.4 | Tag cloud spiral parameters |
| kMaxSpiralIterations | 2000 | Tag cloud placement limit |
