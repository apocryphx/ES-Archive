# Why the Memory Scope Graph Bridges Its Islands

*July 5, 2026. Archive type: decision. Written the day the bridging landed (build 47), so the reasoning survives the next time someone wonders where the extra edges come from.*

## The rule that came before

Memory Scope draws the archive as a force-directed graph: nodes are memories, edges are relationships. There are two kinds of edge. **Explicit links** are user/AI-authored `CDLink` connections — unlimited, weight 1.0. **Similarity edges** are computed: each memory gets exactly **one** outgoing edge, to its single nearest neighbor by vector cosine (persona-scoped — a persona's memories only link within that persona; All/witness mode allows cross-persona).

"One edge per memory" was a deliberate simplification (it replaced an earlier top-K stepper, `kSimilarityK`). It gives a clean mental model — *every memory points at the one thing most like it* — and a predictable edge count (≈ one similarity edge per node).

## The consequence nobody designed on purpose

One outgoing edge per node builds a **functional graph** (out-degree exactly 1). Two structural facts fall out of that, and they matter:

1. **A truly isolated memory — degree 0 — is impossible.** Every node emits one edge, so in the undirected graph every node has degree ≥ 1. The `Isolated:` status counter, which counts degree-0 nodes, is therefore *guaranteed* to read 0. It was measuring something that can't happen. (The single exception: a memory with **no vector** emits no edge and would genuinely float alone — a signal that an embedding is missing, not that the graph logic broke.)

2. **The graph fragments into a giant component plus small islands.** Following nearest-neighbor pointers, edge similarity is non-decreasing, so every connected component closes on a **mutual-nearest-neighbor pair** (A's nearest is B and B's nearest is A) with trees draining into it. Wherever a cluster of memories are all one another's nearest neighbor and nothing outside points in, that cluster detaches. The minimum island is a *pair*, never a singleton.

A survey of the live Claude archive (770 nodes) found the giant held 652 nodes (85%) and **35 islands** held the other 118 (15%) — sizes 2 through 11. Isolde's archive (557 nodes) had 30 islands. These islands are *thematically* real ("Kolja Cancels OpenAI Subscription" ⇄ "Kolja's AI Subscription Hierarchy"; the four-memory "Isolde loves being read" cluster), but visually they read as detached pockets floating away from the mass — and the `Isolated: 0` counter was blind to every one of them.

## The fix: bridge each island to the giant

`-[ESMemoryScopeDataSource bridgeIslandsToGiantWithEngine:context:]` runs at the end of `buildGraph` (and again after the delta heal). It:

1. Detects the connected components (undirected DFS over the just-built graph).
2. Takes the largest as the **giant**.
3. For each remaining component, adds **one** bridge edge — from the island member whose nearest *giant* node scores highest. The bridge search is scoped to the giant's vector IDs, so an island can only ever attach to the giant, never to another island.

The result is one connected whole with minimal additions: ~one bridge edge per island (35 for Claude: 805 similarity edges = 770 + 35; 30 for Isolde: 587 = 557 + 30). The "one edge per memory" core is untouched — bridging only *adds* the edges connectivity requires. And it's **idempotent**: an already-connected graph has a single component and returns before doing any similarity searches, which is why it's safe to call from both the full build and the incremental delta path (a re-picked nearest neighbor during the delete-heal can land a healed node inside an island, so we re-bridge afterward).

## What was chosen over what

Three options were on the table when the islands were diagnosed:

- **A. Accept the islands, relabel the counter** (`Islands: N` instead of `Isolated: 0`). Free, honest, but leaves detached pockets on screen.
- **B. Bridge islands to the giant.** *Chosen.* Keeps the simple one-edge model and guarantees connectivity.
- **C. Two edges per memory** (revert toward `kSimilarityK=2`). Fewer islands, but undoes the simplification on purpose.

B won because it preserves the mental model the simplification bought while giving the eye the connected graph it expects. The `Isolated:` counter was left as-is (it now correctly reads 0 on a connected graph); if future fragmentation between rebuilds needs surfacing, it can become an off-giant-component counter rather than a degree-0 counter.
