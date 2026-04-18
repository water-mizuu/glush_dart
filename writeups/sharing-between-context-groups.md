# Sharing Between Context Groups: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Five Sharing Mechanisms](#five-sharing-mechanisms)
3. [Mechanism 1: SPPF Node Sharing](#mechanism-1-sppf-node-sharing)
4. [Mechanism 2: Mark Tree Branching](#mechanism-2-mark-tree-branching)
5. [Mechanism 3: Label Stack Sharing](#mechanism-3-label-stack-sharing)
6. [Mechanism 4: Context Reuse via Immutability](#mechanism-4-context-reuse-via-immutability)
7. [Mechanism 5: Caller Stack Sharing via GSS](#mechanism-5-caller-stack-sharing-via-gss)
8. [Integration: End-to-End Example](#integration-end-to-end-example)
9. [Why Sharing is Critical](#why-sharing-is-critical)
10. [Consequences of Sharing](#consequences-of-sharing)
11. [Practical Examples](#practical-examples)

---

## Core Concept

Context groups don't exist in isolation. They share structural components across multiple derivation paths:

1. **SPPF nodes** via the deduplication table
2. **Mark forests** through lazy branching
3. **Label stacks** with "first-write" semantics
4. **Parsing context** (caller, position, arguments)
5. **Caller stacks** via the Graph-Shared Stack

This sharing is the foundation of Glush's ability to handle ambiguous grammars efficiently without exponential blowup.

### Location & Key Files

- **Frame Structure**: [lib/src/parser/common/frame.dart](../lib/src/parser/common/frame.dart)
- **Mark Tree Structure**: [lib/src/core/list.dart](../lib/src/core/list.dart) (LazyGlushList)
- **Mark Operations**: [lib/src/core/list_mark_extensions.dart](../lib/src/core/list_mark_extensions.dart)
- **Integration in Step**: [lib/src/parser/common/step.dart](../lib/src/parser/common/step.dart)
- **Label Handling**: [lib/src/parser/common/label_capture.dart](../lib/src/parser/common/label_capture.dart)

---

## Five Sharing Mechanisms

| Mechanism | What's Shared | How | Why |
|-----------|---------------|-----|-----|
| **SPPF Nodes** | Parse forest nodes | Deduplication table | Convergence on same rule/span |
| **Mark Trees** | Semantic annotations | Lazy branching | Multiple derivations |
| **Label Stacks** | Captured labels | First-write | Same rule, same labels |
| **Contexts** | Parser state | Immutability | Reuse across frames |
| **Caller Stacks** | Call trace | GSS nodes | Common call prefixes |

---

## Mechanism 1: SPPF Node Sharing

### Via SppfTable Deduplication

All SPPF nodes are created through `SppfTable`, ensuring sharing:

```dart
// Frame A reaches a symbol node for S over [0..5]
var nodeA = sppfTable.symbol(S_ID, 0, 5);

// Frame B (different derivation) reaches the same symbol
var nodeB = sppfTable.symbol(S_ID, 0, 5);

assert(identical(nodeA, nodeB)); // Same object in memory!
```

### How Deduplication Works

**Location**: [lib/src/parser/common/sppf_table.dart](../lib/src/parser/common/sppf_table.dart)

The `SppfTable` maintains identity-based maps keyed by (type, start, end):

```dart
class SppfTable {
  final Map<int, SymbolNode> _symbolsFast = {};
  final Map<Object, SymbolNode> _symbolsComplex = {};
  
  SymbolNode symbol(PatternSymbol rule, int start, int end) {
    if (rule.id < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      // Fast path: bit-pack key
      var key = (rule.id << 32) | (start << 16) | end;
      return _symbolsFast[key] ??= SymbolNode(rule, start, end);
    }
    // Slow path: Object.hash
    var key = Object.hash(rule, start, end);
    return _symbolsComplex[key] ??= SymbolNode(rule, start, end);
  }
}
```

### Result: Convergence

Multiple derivation paths that span the same rule over the same input range converge on a single node:

```
Derivation Path 1: ... → SymbolNode(S, 0, 5)
Derivation Path 2: ... → SymbolNode(S, 0, 5)  ← Same object!
Derivation Path 3: ... → SymbolNode(S, 0, 5)  ← Same object!
```

### Families Track Differences

While the node is shared, different derivations are tracked via **families**:

```dart
class SymbolNode extends SppfNode {
  List<SppfNode?> families = [];  // One entry per derivation
  
  void addFamily(SppfNode? left, SppfNode right) {
    families.add(SppfFamily(left, right));
  }
}

// All three paths update the same node
nodeA.addFamily(leftA, rightA);  // families = [family1]
nodeB.addFamily(leftB, rightB);  // families = [family1, family2]
nodeC.addFamily(leftC, rightC);  // families = [family1, family2, family3]
```

### Example: Highly Ambiguous Grammar

```
S → S S | 'a'
Input: "aa"
```

Parse forest:

```
        SymbolNode(S, 0, 2)  ← SHARED
       /                    \
    S[0..1]                 S[1..2]
    /
  'a'[0..1]

        SymbolNode(S, 0, 2)  ← SAME NODE
       /                    \
    S[0..2]                 S[2..2]    (impossible, but illustrates sharing)
```

Both derivations that span `[0..2]` reuse the same `SymbolNode(S, 0, 2)`, just with different `families`.

### Memory Impact

Without sharing:
```
n inputs × C_n derivations × nodes_per_tree
= exponential space
```

With sharing:
```
O(n²) nodes (one per span)
+ linear families overhead
= polynomial space
```

---

## Mechanism 2: Mark Tree Branching

**Marks** are semantic annotations (e.g., token matches, rule actions) organized as lazy trees (`LazyGlushList<Mark>`). When context groups accumulate multiple mark streams, they're combined via **lazy branching**.

### Structure: LazyGlushList

**Location**: [lib/src/core/list.dart](../lib/src/core/list.dart)

```dart
sealed class LazyGlushList<T> {
  const factory LazyGlushList.empty() = _EmptyList;
  const factory LazyGlushList.singleton(T item) = _SingletonList;
  const factory LazyGlushList.push(LazyGlushList<T> parent, T item) = _PushList;
  const factory LazyGlushList.branched(
    LazyGlushList<T> left,
    LazyGlushList<T> right,
  ) = _BranchedList;
  
  GlushList<T> evaluate();
  int get length;
}
```

### Lazy Operations

When marks accumulate in context groups:

```dart
// Frame 1: enters rule at position 5
mark1 = LazyGlushList.push(marks0, Mark("enter_rule"))

// Frame 2: same rule at position 5 (different derivation)
mark2 = LazyGlushList.push(marks0, Mark("enter_rule"))

// Both frames converge on ContextGroup
group.addMarks(mark1);
group.addMarks(mark2);

// When accessed, merged via balanced branching
var merged = group.mergedMarks;
// → LazyGlushList.branched(mark1, mark2)
```

### Tree Structure

Two streams of marks combined:

```
Stream 1: Push(Push(Empty, M1), M2)
Stream 2: Push(Push(Empty, M3), M4)

Result: Branched(Stream1, Stream2)
         /           \
    Push(Push())    Push(Push())
```

### Evaluation

Only when `evaluate()` is called:

```dart
LazyGlushList.branched(mark1, mark2).evaluate()
// → GlushList.branched(mark1.evaluate(), mark2.evaluate())
// → Full flattening of trees
```

### Benefits

1. **Lazy**: No merging until needed
2. **Balanced**: Prevents degenerate left-skewed chains (see context-batching.md)
3. **Composable**: Multiple streams can be combined
4. **Efficient Path Enumeration**: Can enumerate all mark paths lazily

---

## Mechanism 3: Label Stack Sharing

Open and closed label stacks are shared with **first-write** semantics.

### Label Representation

**Location**: [lib/src/parser/common/label_capture.dart](../lib/src/parser/common/label_capture.dart)

```dart
// Open labels: currently open (haven't closed yet)
class OpenLabel {
  final String name;
  final int startPosition;
  final OpenLabel? parent;
}

// Closed labels: already closed (recorded in history)
class ClosedLabel {
  final String name;
  final int startPosition;
  final int endPosition;
  final ClosedLabel? parent;
}
```

### First-Write Semantics in ContextGroup

```dart
class ContextGroup {
  OpenLabel? openLabels;      // First non-null value stored
  ClosedLabel? closedLabels;  // First non-null value stored
  
  void addOpenLabels(OpenLabel? labels) {
    openLabels ??= labels;  // Only set if currently null
  }
  
  void addClosedLabels(ClosedLabel? labels) {
    closedLabels ??= labels;
  }
}
```

### Why First-Write?

All frames in a context group:
- Parse the same rule (identical context)
- Accumulate labels in the same order
- Execute the same label actions in sequence

Therefore, only the first frame's label stack is needed:

```dart
// Frame 1 reaches ContextGroup
frame1.labels = OpenLabel("id", 0, null)
group.addOpenLabels(frame1.labels);  // stored

// Frame 2 (different derivation) also reaches ContextGroup
frame2.labels = OpenLabel("id", 0, null)  // identical!
group.addOpenLabels(frame2.labels);  // ✗ ignored, already set
```

### Memory Impact

Single label stack per context group instead of one per frame:

```
Without sharing: N frames × label_stack_size = memory
With sharing:    1 label_stack per group + frames point to it
```

---

## Mechanism 4: Context Reuse via Immutability

`Context` objects are **immutable** and widely shared. The same context object can be reused across multiple frames and groups.

### Location & Structure

**Location**: [lib/src/parser/common/context.dart:20-183](lib/src/parser/common/context.dart#L20-L183)

```dart
class Context {
  final CallerKey caller;
  final Map<String, Object?> arguments;
  final CaptureBindings captures;
  final GlushList<PredicateCallerKey> predicateStack;
  final int callStart;
  final int position;
  final int? minPrecedenceLevel;
  final int? precedenceLevel;
  
  Context copyWith({...}) {
    return Context(...);  // Creates new context only if something changes
  }
}
```

### Identity-Based Comparison

Two frames with the **same Context object** (identity) are guaranteed equivalent:

```dart
// Frame A and Frame B both have context object C
frame_a.context === frame_b.context  // true

// In batching lookup
if (fast_lookup[packed_id] case var group?) {
  // Group.context === next_context
  // So they're equivalent without comparison!
}
```

### Copying Strategy

New contexts are created only when fields change:

```dart
// Advance position: create new context
context.advancePosition(5)
  → Context(..., position: 5, ...)

// Same position: reuse existing context
context.advancePosition(position)
  → return this;  // Same object
```

### Result: Massive Sharing

The same `Context` object is referenced by:
- Multiple frames
- Multiple context groups
- Multiple derivation paths

Example:

```
Context C = Context(caller=main, position=10, ...)

Frame 1 → ContextGroup A → C
Frame 2 → ContextGroup A → C
Frame 3 → ContextGroup B → C
Frame 4 → ContextGroup B → C

All four frames share the same Context object!
```

---

## Mechanism 5: Caller Stack Sharing via GSS

The **Graph-Shared Stack (GSS)** is represented as a linked list of `Caller` nodes. Multiple parse paths share common `Caller` prefixes.

### GSS Concept

**Location**: [lib/src/parser/common/context.dart](../lib/src/parser/common/context.dart)

```
// Path 1: main() → rule1() → rule2()
// Path 2: main() → rule1() → rule3()
//
// Both share: main → rule1
//            /        \
//        rule2()    rule3()

// In memory:
  Caller(main, null)                    ← root, SHARED
    ↓
  Caller(rule1, parent=main)            ← SHARED between paths
    ↙                   ↘
Caller(rule2, ...)    Caller(rule3, ...)   ← path-specific
```

### Immutable Linked List

```dart
sealed class CallerKey {
  const CallerKey();
}

class RootCaller extends CallerKey {
  const RootCaller();
}

class Caller extends CallerKey {
  final CallerKey parent;           // Previous caller
  final PatternSymbol ruleId;       // Which rule was called
  final Map<String, Object?> arguments; // Rule args
  final int startPosition;          // Where rule started
  
  const Caller({
    required this.parent,
    required this.ruleId,
    this.arguments = const {},
    required this.startPosition,
  });
}
```

### Sharing via Context Reuse

When frames have the same caller path, they reuse the same `CallerKey` object:

```dart
// Frame A: enters rule1 from main at position 0
var caller_a = Caller(
  parent: rootCaller,
  ruleId: rule1,
  startPosition: 0,
);

// Frame B: same call sequence (different derivation)
var caller_b = Caller(
  parent: rootCaller,
  ruleId: rule1,
  startPosition: 0,
);

// If caller_a and caller_b are equal, they share the same object
// (via memoization in Glush's call stack management)
assert(identical(caller_a, caller_b));  // Might be true!
```

### Memory Impact

Without sharing:
```
N frames × depth of recursion × pointer chain
= exponential memory for deep recursive rules
```

With sharing:
```
O(recursion depth) shared prefix
+ path-specific divergence
= polynomial memory
```

---

## Integration: End-to-End Example

Here's how all five sharing mechanisms work together:

### Step 1: Token Consumed

Parser processes token 'a' at position 3, advancing to position 4:

```dart
// Current frame
frame = Frame(
  context: Context(caller: rule1_caller, position: 3, ...),
  marks: LazyGlushList.push(prevMarks, Mark("enter_rule")),
  sppfNode: SymbolNode(rule1_partial, 2, 3),
  openLabels: OpenLabel("expr", 2, null),
);

// Action fires: consume token, create new context
nextContext = frame.context.copyWith(position: 4);  // Mechanism 4: Immutable copy
nextMarks = LazyGlushList.push(frame.marks, Mark("consume_a"));
nextSppfNode = sppfTable.symbol(rule1, 2, 4);  // Mechanism 1: Dedup table
```

### Step 2: Batching Lookup

Check if another frame reached the same state with the same context:

```dart
if (nextContext.isSimple) {
  var packedId = (nextContext.caller.uid << 32) | (state.id << 8) | 0xFF;
  
  // Mechanism 1: SPPF dedup via table
  // Mechanism 3: Label sharing (first-write)
  // Mechanism 5: Caller stack sharing (caller in context)
  
  var group = _nextFrameGroupsInt[packedId];
  
  if (group != null) {
    // Mechanism 2: Mark tree branching
    group.addMarks(nextMarks);  // Lazy push, not evaluation
    group.addSppfNode(nextSppfNode);
    group.addOpenLabels(frame.openLabels);  // First-write
    return;  // No new frame created
  }
}

// First time reaching this context/state
_nextFrameGroupsInt[packedId] = ContextGroup(state, nextContext)
  ..addMarks(nextMarks)
  ..addSppfNode(nextSppfNode)
  ..addOpenLabels(frame.openLabels);
```

### Step 3: Second Frame Arrives

Different derivation path, same rule/state:

```dart
// Frame 2 (different derivation path)
frame2 = Frame(
  context: Context(caller: rule1_caller, position: 3, ...),  // Mechanism 4: Same context
  marks: LazyGlushList.push(otherMarks, Mark("alt_derive")),
  sppfNode: SymbolNode(rule1, 2, 4),  // Mechanism 1: Same node!
  openLabels: OpenLabel("expr", 2, null),  // Mechanism 3: First-write
);

// Action fires, creates nextContext
nextContext2 = frame2.context.copyWith(position: 4);  // Mechanism 4: Identity == nextContext
nextMarks2 = LazyGlushList.push(otherMarks, Mark("alt_derive"));
nextSppfNode2 = sppfTable.symbol(rule1, 2, 4);  // Mechanism 1: Identical node!

// Batching lookup
var packedId2 = (nextContext2.caller.uid << 32) | (state.id << 8) | 0xFF;
assert(packedId2 == packedId);  // Same key!

var group = _nextFrameGroupsInt[packedId2];
assert(group != null);  // Already exists from Frame 1

// Mechanism 2: Lazy mark merging (not yet evaluated)
group.addMarks(nextMarks2);  // Just appends to batch
// Mechanism 3: Label sharing
group.addOpenLabels(frame2.openLabels);  // ✗ Ignored, already set (first-write)
```

### Step 4: Finalization

Convert batches to frames for next position:

```dart
void finalize() {
  for (var nextGroup in _nextFrameGroupsInt.values) {
    // Mechanism 2: Lazy marks merged into balanced tree NOW
    var branchedMarks = nextGroup.mergedMarks;  // Lazy evaluation
    // Result: LazyGlushList.branched(
    //   LazyGlushList.push(prevMarks, Mark("consume_a")),
    //   LazyGlushList.push(otherMarks, Mark("alt_derive")),
    // )
    
    // Mechanism 1: Shared SPPF node
    var frame = Frame(
      nextGroup.context,  // Mechanism 4: Immutable, shared
      branchedMarks,      // Mechanism 2: Lazy tree with both paths
      sppfNode: nextGroup.sppfNode,  // Mechanism 1: Shared SymbolNode
      openLabels: nextGroup.openLabels,  // Mechanism 3: Shared (first-write)
    );
    
    nextFrames.add(frame);
  }
}
```

### Step 5: Post-Parse Evaluation

Enumerate all derivations:

```dart
// Later, after parsing completes
forest.allMarkPaths()  // Mechanism 2: Enumerate via mark tree
  .evaluate()          // Lazy evaluation of branched structure
  .forEach((marks) {
    // Process each derivation
    var derivation = evaluateMarks(marks);
    results.add(derivation);
  });
```

---

## Why Sharing is Critical

### 1. Prevents Exponential Explosion

Without sharing:
```
Grammar: S → S S | 'a'
Input: "aaaaa"
Frames without sharing: ~1000+
Memory: Exponential
```

With sharing:
```
Grammar: S → S S | 'a'
Input: "aaaaa"
Frames with sharing: ~5-10 context groups
Memory: Polynomial
```

### 2. Enables Ambiguity

Multiple derivations add to families in a single shared SPPF node:

```dart
// All 42 derivations of S over [0..5] share one SymbolNode
symbolNode = sppfTable.symbol(S, 0, 5);
symbolNode.families.length == 42;  // All tracked
```

### 3. Memory Efficiency

Structural sharing reduces footprint:

```
Without sharing: N frames × context_size × mark_tree_size × ...
With sharing:
  - Same context reused
  - Same marks lazily combined
  - Same SPPF node shared
  - Same label stacks first-write
  - Same caller prefixes in GSS
→ Polynomial memory
```

### 4. Lazy Evaluation

Defers work until needed:

```dart
// Mark trees are NOT evaluated during parsing
group.addMarks(m1);
group.addMarks(m2);
group.addMarks(m3);
// Still not evaluated

// Only when we need paths
forest.allMarkPaths().evaluate();  // Now it's expensive, but only once
```

### 5. Data-Driven Parsing

Label index on SymbolNode enables O(1) queries:

```dart
// Can query labels without post-traversal
symbolNode.labelFor("identifier");  // O(1) lookup
```

---

## Consequences of Sharing

### 1. Ordering Doesn't Matter

Since marks are lazily combined and derivations are stored in families:

```dart
// These two frame orderings produce the same result
Sequence 1: [frame1, frame2, frame3]
Sequence 2: [frame3, frame1, frame2]

// Both converge on the same ContextGroup with same merged marks
```

### 2. Deterministic Results

Despite multiple derivations:

```dart
// Frame A, B, C all reach SymbolNode(S, 0, 5)
// Regardless of exploration order, same node is shared
// Same families recorded
// Enumerating derivations always produces same set
```

### 3. Memory Sharing is Transparent

Users don't need to think about sharing:

```dart
// Just write grammars; sharing happens automatically
rule = inner | other;

// Glush handles deduplication internally
// No manual memoization needed
```

### 4. Identity Can Be Relied Upon

Context/SPPF node identity is meaningful:

```dart
// If two frames have identical context objects
// They explore the same state and produce compatible results
if (context1 === context2) {
  // Can safely batch these frames
}
```

---

## Practical Examples

### Example 1: Simple Ambiguity

```dart
// Grammar
S → S '+' S | num

// Input: "1 + 2 + 3"

// Parse tree (two derivations):
// Derivation 1: (1 + 2) + 3
// Derivation 2: 1 + (2 + 3)

// Sharing:
SymbolNode(S, 0, 5)  ← Shared!
  ├─ Family 1: left=S[0..3], right=S[3..5]  (+ 3)
  └─ Family 2: left=S[0..1], right=S[1..5]  (1 + ...)

// Memory: One SymbolNode
// Without sharing: Two separate parse trees
```

### Example 2: Highly Ambiguous

```dart
// Grammar
S → S S | 'a'

// Input: "aaaa"

// All derivations share via SPPF deduplication:
SymbolNode(S, 0, 4)  ← All 14 derivations converge!
  ├─ Family 1: S[0..1] S[1..4]
  ├─ Family 2: S[0..2] S[2..4]
  ├─ Family 3: S[0..3] S[3..4]
  └─ ...

// Mark trees branch for different paths:
mergedMarks = Branched(
  Branched(path1_marks, path2_marks),
  Branched(path3_marks, path4_marks),
  // ...
)

// Memory: Polynomial in input length
// Without sharing: Exponential!
```

### Example 3: Deep Recursion with Caller Sharing

```dart
// Grammar
main() → rule1()
rule1() → rule2()
rule2() → 'a' | 'b'

// Input: "ab"

// Caller stacks (shared prefix):
main_caller
  ↓
rule1_caller  (shared by both 'a' and 'b' frames)
  ↙         ↘
frame_a    frame_b

// Memory: O(depth) instead of O(frames × depth)
```

---

## Summary

Sharing between context groups is achieved through five complementary mechanisms:

1. **SPPF Nodes**: Deduplication table ensures convergence on same (rule, span)
2. **Mark Trees**: Lazy branching combines multiple derivations without evaluation
3. **Label Stacks**: First-write semantics reduces overhead
4. **Contexts**: Immutable, reused across frames and groups
5. **Caller Stacks**: GSS shares common call prefixes

Together, these mechanisms transform exponential memory and time complexity into polynomial, enabling Glush to efficiently handle highly ambiguous grammars. Sharing is transparent to the user—Glush handles deduplication automatically while maintaining deterministic, complete parse results.
