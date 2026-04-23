# Investigation: Incremental Parsing in Glush

This document explores the feasibility and architectural requirements for transforming the `glush_dart` state machine parser into an incremental parser.

## 1. Objectives
- **Mutable State with Structural Sharing**: The `IncrementalParseState` will be mutable but will exploit structural sharing (immutable GSS nodes and forest nodes) across versions.
- **Sub-Linear Complexity**: Management operations (position shifting, invalidation) must perform in $O(\log N)$ time.
- **Highly Ambiguous Support**: Robust re-synchronization that accounts for all active branches in the GSS and prevents derivation corruption.
- **Performance-First Design**: Incorporates sparse snapshotting, lazy invalidation, and prioritized re-parsing for low-latency IDE feedback.

## 2. Position Management (The `PositionManager`)
To achieve logarithmic position shifting, we must move away from absolute `int` indices.
- **Data Structure**: **2-3 Finger Tree**.
- **Nodes**: Internal nodes are augmented with `totalLength` (the sum of lengths of all leaf tokens in the subtree).
- **Algorithm**:
    - **Position Resolution**: Finding the absolute index of a `Position` object involves traversing from root to leaf, summing the `totalLength` of left-siblings. $O(\log N)$.
    - **Edit (Insert/Delete)**: Perform a `split` at the edit point, modify/insert the new segment, and `concat` the tree back. $O(\log N)$.
- **Position Identity Invariant**:
    > [!IMPORTANT]
    > `Position` objects must use **object identity** (pointer equality) for comparison and hashing. Using resolved integer values as `HashMap` keys will lead to silent corruption when positions shift.

## 3. Dependency Tracking (The `IntervalIndex`)
Finding affected snapshots or memoized results must be done in sub-linear time.
- **Data Structure**: **Augmented Red-Black Tree** (Interval Tree).
- **Augmentation**: Each node stores `maxEnd`, the maximum `endPosition` found in its subtree.
- **Stored Intervals**:
    - **Rule Results**: `[start, end]` of a successful rule match.
    - **Lookahead**: `[start, furthestPeek]` for predicates.
    - **Tokens**: `[start, end]` for lexer caching.
- **Algorithms**:
    - **Invalidation Query**: For an edit at $k$, discard results where $s < k < e$ (the edit falls inside the match).
    - **Shifting Concern**: Results where $s \geq k$ do not need invalidation; their positions are shifted automatically by the `PositionManager`.

## 4. Fast Re-synchronization
The "Cut" algorithm stops re-parsing when the current parser state matches the original at the same position.

### A. Frame-Set Matching (Zobrist Hashing)
- **Mechanism**: Maintain a rolling hash of the frame set at each step using **Zobrist Hashing** (XOR Sum).
- **Algorithm**: Each unique `Frame` is assigned a random 64-bit ID. The `ContextGroup` hash is the XOR sum of its frame IDs.
- **Complexity**: $O(1)$ for hash comparison; fallback to $O(N)$ full set check only on collision.

### B. GSS Topology Matching (Bounded Subgraph Hashing)
In ambiguous grammars, matching frame sets is insufficient. We must verify that the **GSS topology** is structurally equivalent.
- **Algorithm**: Each `Caller` node maintains a `topologicalHash = hash(ruleId, startPos, parent.topologicalHash)`.
- **Validation**: Compare the `topologicalHash` of the `Caller` nodes associated with each frame to ensure derivational compatibility.

## 5. Advanced Optimizations

### A. Sparse Snapshotting
Instead of storing a `StepSnapshot` at every position, we only record snapshots at "structurally significant" points (e.g., top-level rule boundaries, statement ends). This minimizes memory and tree-management overhead while accepting a small $O(\text{checkpoint\_dist})$ re-parse cost.

### B. Lazy Invalidation & Edit Coalescing
- **Coalescing**: Multiple incoming edits are merged into a single compound edit before processing.
- **Lazy Invalidation**: Affected regions in the `IntervalIndex` are marked as "dirty." Invalidation and re-parsing are only triggered when the results are actually queried (e.g., for syntax highlighting).

### C. Prioritized Re-parsing (The `CursorWorkQueue`)
- **Data Structure**: **Priority Queue** of `Step` tasks, where priority is inversely proportional to the distance from the user's cursor.
- **Algorithm**: The parser prioritizes the current statement/block first to provide immediate feedback, then expands the re-parse window outward in the background.

## 6. Error Recovery & Partial States
- **Empty Frame Handling**: If a `Step` results in an empty set, trigger a recovery strategy (e.g., Panic Mode) to find the next valid synchronization point.
- **State Persistence**: Snapshots before the error remain valid, allowing for instant resumption once the syntax is corrected.

## 7. Implementation Roadmap (Conceptual)

1. **Refactor Positions**: Move to a Finger Tree-backed `Position` type.
2. **Logarithmic History**: Implement sparse snapshot storage in a balanced tree.
3. **Interval Indexing**: Implement an Interval Tree for `Caller` results, `Predicate` ranges, and `Token` boundaries.
4. **Edit API**: Implement coalescing and lazy invalidation.
5. **Resync Logic**: Implement Zobrist hashing and GSS topology matching.
6. **Mark Patching**: Merge spliced forest nodes using stable identities to avoid ambiguity corruption.

## 8. Conclusion
Glush's GLL-based state machine is ideally suited for state-of-the-art incremental parsing. By combining structural sharing, Finger Trees, and Interval Trees, we can provide near-instant feedback in even the most complex and ambiguous grammars.
