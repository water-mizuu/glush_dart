# Investigation: Scannerless Incremental Parsing in a Pure CFG Glush Variant

This document explores the exact architectural requirements, algorithms, and data structures for transforming the `glush_dart` state machine parser into a scannerless (character-level) incremental parser. This focuses on the `cfg` branch, utilizing a pure Context-Free Grammar model without conjunctions.

## 1. Objectives
- **Scannerless Incremental Parsing**: No lexer phase is used. All increments, invalidations, and positions operate exactly at the character level.
- **Mutable State with Structural Sharing**: The `IncrementalParseState` exploits structural sharing (immutable GSS nodes and forest nodes) across versions.
- **Sub-Linear Complexity**: Management operations (position shifting, invalidation) must perform in $O(\log N)$ time where $N$ is the number of tracked characters/segments.
- **Pure CFG Semantics**: Without conjunctions, the Graph-Structured Stack (GSS) and Shared Packed Parse Forest (SPPF) track standard ambiguity (disjunctions) only, eliminating intersection tracking.

## 2. Position Management (2-3 Finger Tree)
To achieve logarithmic position shifting for character edits, we use a 2-3 Finger Tree augmented with character lengths.

### Data Structure Definition
```dart
abstract class FingerTree {
  int get charLength; // The total number of characters in this subtree
}

class DeepTree extends FingerTree {
  final int charLength;
  final Digit left;
  final FingerTree middle; // Tree of Node2/Node3
  final Digit right;
  // ...
}

class LeafNode extends FingerTree {
  final String textSegment;
  int get charLength => textSegment.length;
}
```

### Exact Algorithms
- **Position Resolution (`O(log N)`)**:
  Traverse the tree from root to leaf. At each node, if the target index is less than `left.charLength`, recurse left. Otherwise, subtract `left.charLength` and recurse right.
- **Edit (`O(log N)`)**:
  To replace text at `[start, end]`:
  1. `(leftTree, remainder) = tree.split(start)`
  2. `(deletedTree, rightTree) = remainder.split(end - start)`
  3. `newTree = leftTree.concat(LeafNode(newText)).concat(rightTree)`

## 3. Dependency Tracking (Augmented Interval Tree)
Since we are scannerless, we must track the exact character spans of successful rule matches (memoized results) to invalidate them efficiently upon edits.

### Data Structure Definition
```dart
class IntervalNode {
  final int start;
  final int end;
  int maxEnd; // Augmented property: maximum 'end' in this subtree
  final ParseResult result;
  
  IntervalNode? left;
  IntervalNode? right;
  bool isRed;
}
```

### Exact Algorithms
- **Insertion**: Standard Red-Black tree insertion using `start` as the primary key. `maxEnd` is recalculated on the path back to the root (`node.maxEnd = max(node.end, node.left?.maxEnd, node.right?.maxEnd)`).
- **Invalidation Query (`O(log N + K)`)**:
  To find all results affected by an edit at character `k`:
  ```dart
  void findOverlapping(IntervalNode? node, int k, List<ParseResult> out) {
    if (node == null || node.maxEnd <= k) return; // Prune search
    if (node.start <= k && node.end > k) out.add(node.result);
    if (node.left != null) findOverlapping(node.left, k, out);
    if (node.start <= k && node.right != null) findOverlapping(node.right, k, out);
  }
  ```

## 4. Fast Re-synchronization (Zobrist & Topology Hashing)
The "Cut" algorithm stops re-parsing when the current parser state exactly matches a previously memoized state.

### A. Frame-Set Matching (Zobrist Hashing)
```dart
class FrameSignature {
  final int ruleId;
  final int dotIndex;
  // Position is implied by the tree level, so we hash rule and state
}

class ZobristHasher {
  static final Map<FrameSignature, int> _randomHashes = {};
  int currentHash = 0;

  void addFrame(FrameSignature sig) {
    _randomHashes.putIfAbsent(sig, () => _generateRandom64BitInt());
    currentHash ^= _randomHashes[sig]!; // XOR sum
  }
}
```

### B. GSS Topology Matching
In ambiguous scannerless grammars, we must verify that the **GSS topology** is structurally equivalent.
```dart
class CallerNode {
  final int ruleId;
  final int startPos;
  final CallerNode? parent;
  late final int topologicalHash;

  CallerNode(this.ruleId, this.startPos, this.parent) {
    topologicalHash = Object.hash(ruleId, startPos, parent?.topologicalHash);
  }
}
```

## 5. Validation of Claims
- **$O(\log N)$ Scannerless Shifting**: Finger Trees are the theoretical foundation of modern functional text buffers (e.g., Yi editor). Augmenting them by character count guarantees strict logarithmic bounds regardless of token density.
- **Scannerless Interval Trees**: Because characters are granular, the interval tree will be dense. Red-Black trees guarantee $O(\log N)$ worst-case height, meaning pruning via `maxEnd` remains strictly optimal.
- **Zobrist Hashing**: Using XOR sums for unordered sets provides an $O(1)$ equality check with statistically negligible collision rates, avoiding expensive $O(F)$ set-intersection comparisons at every character step.

## 6. What We Can Improve Further (Pure CFG Optimizations)

### A. Deterministic Fast-Paths (GSS Bypass)
Scannerless parsing often suffers from heavy GSS allocations for simple character sequences (e.g., matching the literal `"while"`). 
**Algorithm**:
- Analyze the grammar for $LL(1)$ character sub-languages.
- Use a standard `List<int>` array stack for these deterministic paths.
- Only construct heap-allocated `CallerNode` and `Frame` objects when an actual ambiguity (disjunction) is reached.

### B. Subtree Re-use (The Papa Carlo Approach)
Instead of re-parsing top-down from an invalidated character, identify fully intact SPPF subtrees from the previous parse that span past the edit window.
**Algorithm**:
- When the parser reaches a position `P`, query the `IntervalIndex` for a valid, non-intersecting rule result starting at `P`.
- If found, shift the parser position by `result.length` and directly push the cached SPPF node onto the GSS, bypassing character-by-character execution.

### C. Table-Driven Execution
Compile the scannerless CFG into a static byte-code or shift-reduce table. 
- **Benefit**: Snapshotting becomes trivial. A parser state is simply a pointer to a GSS node and an integer Program Counter (PC).

## 7. Implementation Roadmap (Exact Patterns)

1. **Finger Tree Core**: Implement `Deep`, `Digit`, and `Node` structures strictly typed for character counting.
2. **Interval Tree Core**: Implement the `maxEnd` augmented Red-Black tree for `ParseResult` caching.
3. **Immutability Pattern**: Convert `ParseState` to use copy-on-write semantics. Updates return a new state reference while sharing underlying FingerTree and IntervalTree roots.
4. **Zobrist Integration**: Update the `ContextGroup` reduction phase to compute XOR sums over active frames.
5. **Fast-Path Fallback**: Implement the fast Array-stack and the promotion mechanism that upgrades to a GSS stack upon hitting a disjunction.
