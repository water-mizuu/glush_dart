# Sharing Between Context Groups: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Four Sharing Mechanisms](#four-sharing-mechanisms)
3. [Mechanism 1: Mark Tree Branching](#mechanism-1-mark-tree-branching)
4. [Mechanism 2: Label Stack Sharing](#mechanism-2-label-stack-sharing)
5. [Mechanism 3: Context Reuse via Immutability](#mechanism-3-context-reuse-via-immutability)
6. [Mechanism 4: Caller Stack Sharing via GSS](#mechanism-4-caller-stack-sharing-via-gss)
7. [Integration: End-to-End Example](#integration-end-to-end-example)
8. [Why Sharing is Critical](#why-sharing-is-critical)
9. [Consequences of Sharing](#consequences-of-sharing)
10. [Practical Examples](#practical-examples)

---

## Core Concept

Context groups don't exist in isolation. They share structural components across multiple derivation paths:

1. **Mark forests** through lazy branching
2. **Context identity** (caller, position, labels, arguments)
3. **Caller stacks** via the Graph-Shared Stack (GSS)

This sharing is the foundation of Glush's ability to handle ambiguous grammars efficiently without exponential blowup.

### Location & Key Files

- **Frame Structure**: [lib/src/parser/common/frame.dart](../lib/src/parser/common/frame.dart)
- **Mark Tree Structure**: [lib/src/core/list.dart](../lib/src/core/list.dart) (LazyGlushList)
- **Mark Operations**: [lib/src/core/list_mark_extensions.dart](../lib/src/core/list_mark_extensions.dart)
- **Integration in Step**: [lib/src/parser/common/step.dart](../lib/src/parser/common/step.dart)
- **Label Handling**: [lib/src/parser/common/label_capture.dart](../lib/src/parser/common/label_capture.dart)

---

## Four Sharing Mechanisms

| Mechanism         | What's Shared        | How                 | Why                           |
| ----------------- | -------------------- | ------------------- | ----------------------------- |
| **Mark Trees**    | Semantic annotations | Lazy branching      | Multiple derivations          |
| **Contexts**      | Parser state         | Immutability        | Reuse across frames (includes Labels) |
| **Caller Stacks** | Call trace           | GSS nodes           | Common call prefixes          |

---


---

## Mechanism 1: Mark Tree Branching

**Marks** are semantic annotations (e.g., token matches, rule actions) organized as lazy trees (`LazyGlushList<Mark>`). When context groups accumulate multiple mark streams, they're combined via **lazy branching**.

### Structure: LazyGlushList

**Location**: [lib/src/core/list.dart](../lib/src/core/list.dart)

```dart
sealed class LazyGlushList<T> {
  const factory LazyGlushList.empty() = LazyEmpty<T>._;

  LazyGlushList<T> add(LazyVal<T> val);
  LazyGlushList<T> addList(LazyGlushList<T> other);
  static LazyGlushList<T> branched<T>(LazyGlushList<T> left, LazyGlushList<T> right);

  GlushList<T> evaluate();
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

## Mechanism 2: Label Stack Sharing (via Context Identity)

In Glush, **labels** (open/closed stacks) are not managed separately from the parsing context. Instead, they are an integral part of the `Context` object's identity.

### Structural Sharing

**Location**: [lib/src/parser/common/context.dart](../lib/src/parser/common/context.dart)

```dart
class Context {
  final CallerKey caller;
  final GlushList<LabelStartVal> openLabels; // Label stack is part of Context!
  // ... other fields
}
```

### Why Identity Matters

Because `openLabels` is included in the `Context`'s equality and hash code:

1. **Frames with the same labels** share the same `Context` object (via immutability and identity).
2. **Batching** in `ContextGroup` only occurs for frames with identical `Context` objects.
3. Therefore, every frame in a `ContextGroup` is guaranteed to have the **exact same label stack**.

### Sharing via Immutability

Label stacks themselves use `GlushList` (Mechanism 1), which means they share prefixes between derivation paths. When a rule is entered, a new label is "pushed" onto the immutable list, creating a new `Context` that shares the previous list as its parent.

```dart
// Path A and B share prefix, but A enters a new label
contextA = parentContext.copyWith(openLabels: parentContext.openLabels.add(labelStart));
```

This ensures that memory for label stacks remains polynomial even in highly ambiguous or deeply nested grammars.

---

## Mechanism 3: Context Reuse via Immutability

`Context` objects are **immutable** and widely shared. The same context object can be reused across multiple frames and groups.

### Location & Structure

**Location**: [lib/src/parser/common/context.dart](../lib/src/parser/common/context.dart)

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

## Mechanism 4: Caller Stack Sharing via GSS

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
  openLabels: OpenLabel("expr", 2, null),
);

// Action fires: consume token, create new context
nextContext = frame.context.copyWith(position: 4);  // Mechanism 3: Immutable copy
nextMarks = LazyGlushList.push(frame.marks, Mark("consume_a"));
```

### Step 2: Batching Lookup

Check if another frame reached the same state with the same context:

```dart
if (nextContext.isSimple) {
  var packedId = (nextContext.caller.uid << 32) | (state.id << 8) | 0xFF;

  // Mechanism 2: Label sharing (first-write)
  // Mechanism 4: Caller stack sharing (caller in context)

  var group = _nextFrameGroupsInt[packedId];

  if (group != null) {
    // Mechanism 1: Mark tree branching
    group.addMarks(nextMarks);  // Lazy push, not evaluation
    group.addOpenLabels(frame.openLabels);  // First-write
    return;  // No new frame created
  }
}

// First time reaching this context/state
_nextFrameGroupsInt[packedId] = ContextGroup(state, nextContext)
  ..addMarks(nextMarks)
  ..addOpenLabels(frame.openLabels);
```

### Step 3: Second Frame Arrives

Different derivation path, same rule/state:

```dart
// Frame 2 (different derivation path)
frame2 = Frame(
  context: Context(caller: rule1_caller, position: 3, ...),  // Mechanism 3: Same context
  marks: LazyGlushList.push(otherMarks, Mark("alt_derive")),
  openLabels: OpenLabel("expr", 2, null),  // Mechanism 2: First-write
);

// Action fires, creates nextContext
nextContext2 = frame2.context.copyWith(position: 4);  // Mechanism 3: Identity == nextContext
nextMarks2 = LazyGlushList.push(otherMarks, Mark("alt_derive"));

// Batching lookup
var packedId2 = (nextContext2.caller.uid << 32) | (state.id << 8) | 0xFF;
assert(packedId2 == packedId);  // Same key!

var group = _nextFrameGroupsInt[packedId2];
assert(group != null);  // Already exists from Frame 1

// Mechanism 1: Lazy mark merging (not yet evaluated)
group.addMarks(nextMarks2);  // Just appends to batch
// Mechanism 2: Label sharing
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

    // Mechanism 1: Mark tree branching
    var frame = Frame(
      nextGroup.context,  // Mechanism 3: Immutable, shared
      branchedMarks,      // Mechanism 1: Lazy tree with both paths
      openLabels: nextGroup.openLabels,  // Mechanism 2: Shared (first-write)
    );

    nextFrames.add(frame);
  }
}
```

### Step 5: Post-Parse Evaluation

Enumerate all derivations:

```dart
// Later, after parsing completes
forest.allMarkPaths()  // Mechanism 1: Enumerate via mark tree
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

### 2. Memory Efficiency

Structural sharing reduces footprint:

```
Without sharing: N frames × context_size × mark_tree_size × ...
With sharing:
  - Same context reused
  - Same marks lazily combined
  - Same label stacks first-write
  - Same caller prefixes in GSS
→ Polynomial memory
```

### 3. Lazy Evaluation

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
// Frame A, B, C all reach same rule/state with same context
// Regardless of exploration order, same context group is shared
// Enumerating derivations always produces same set
```

### 3. Memory Sharing is Transparent

// Glush handles deduplication internally
// No manual memoization needed

### 4. Identity Can Be Relied Upon

Context identity is meaningful:

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
ContextGroup(S, [0..5])  ← Shared!
  ├─ Path 1: (1 + 2) + 3
  └─ Path 2: 1 + (2 + 3)

// Memory: One ContextGroup
// Without sharing: Two separate parse frames
```

### Example 2: Highly Ambiguous

```dart
// Grammar
S → S S | 'a'

// Input: "aaaa"

// All derivations share via deduplication:
ContextGroup(S, [0..4])  ← All 14 derivations converge!
  ├─ Path 1: S[0..1] S[1..4]
  ├─ Path 2: S[0..2] S[2..4]
  ├─ Path 3: S[0..3] S[3..4]
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

Sharing between context groups is achieved through four complementary mechanisms:

1. **Mark Trees**: Lazy branching combines multiple derivations without evaluation
2. **Label Stacks**: First-write semantics reduces overhead
3. **Contexts**: Immutable, reused across frames and groups
4. **Caller Stacks**: GSS shares common call prefixes

Together, these mechanisms transform exponential memory and time complexity into polynomial, enabling Glush to efficiently handle highly ambiguous grammars. Sharing is transparent to the user—Glush handles deduplication automatically while maintaining deterministic, complete parse results.
