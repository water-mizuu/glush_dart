# Context Batching: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Context Structure](#context-structure)
3. [ContextGroup Batching](#contextgroup-batching)
4. [Two-Tier Strategy](#two-tier-strategy)
5. [Fast Path: Simple Contexts](#fast-path-simple-contexts)
6. [Slow Path: Complex Contexts](#slow-path-complex-contexts)
7. [Balanced Tree Merging](#balanced-tree-merging)
8. [Batching Modes](#batching-modes)
9. [Current-Position vs. Next-Position](#current-position-vs-next-position)
10. [Confusion Points Clarified](#confusion-points-clarified)
11. [Why Context Batching Matters](#why-context-batching-matters)
12. [Integration Example](#integration-example)

---

## Core Concept

**Context Batching** is an optimization that groups multiple parse frames that advance to the same parser state but originate from different derivation paths. By batching frames with the same target state and execution context, Glush:

1. Reduces duplicate state exploration
2. Merges mark streams efficiently
3. Amortizes SPPF node creation across multiple derivations

### Location & Key Files

- **Core Batching Logic**: [lib/src/parser/common/step.dart](../lib/src/parser/common/step.dart) (lines 70-750)
- **Context Definition**: [lib/src/parser/common/context.dart:10-268](../lib/src/parser/common/context.dart#L10-L268)
- **Batching Orchestration**: [lib/src/parser/common/step.dart:292-410](../lib/src/parser/common/step.dart#L292-L410)

---

## Context Structure

A **Context** represents the complete parsing configuration at a point:

```dart
class Context {
  final CallerKey caller;              // GSS node (call stack)
  final Map<String, Object?> arguments; // Rule arguments
  final CaptureBindings captures;      // Data-captured labels
  final GlushList<PredicateCallerKey> predicateStack; // Active lookahead
  final int callStart;                 // Start of current rule call
  final int position;                  // Current parse position
  final int? minPrecedenceLevel;       // Precedence constraint
  final int? precedenceLevel;          // Rule's precedence level
  
  final bool isSimple; // No predicates, captures, or arguments
}
```

### Components

**CallerKey**: The call stack (Graph-Shared Stack node)
- Represents the sequence of rule invocations leading to current position
- Immutable and shared across frames

**arguments**: Rule-specific arguments passed to parameterized rules
- `Map<String, Object?>`
- Only populated for rules with data-driven parameters

**captures**: Data-captured labels (from capture bindings)
- Maps label names to extracted values
- Accumulated during parsing

**predicateStack**: Active lookahead predicates
- `GlushList<PredicateCallerKey>`
- Tracks which predicates are currently active
- Used for nested predicate handling

**callStart**: Start position of the current rule invocation
- Used to compute span indices for SPPF nodes

**position**: Current parse position in the input
- Most frequently changing field

**minPrecedenceLevel**: Precedence constraint for disambiguation
- Used in precedence-climbing rules
- Optional (null when unconstrained)

**precedenceLevel**: The rule's declared precedence
- Set when entering a precedence-aware rule

### Context Equality

Two frames are equivalent if they have **identical contexts**—they can explore the same state and produce compatible results.

```dart
bool contextEquals(Context a, Context b) {
  return a.caller == b.caller &&
         a.arguments == b.arguments &&
         a.captures == b.captures &&
         a.predicateStack == b.predicateStack &&
         a.callStart == b.callStart &&
         a.position == b.position &&
         a.minPrecedenceLevel == b.minPrecedenceLevel &&
         a.precedenceLevel == b.precedenceLevel;
}
```

---

## ContextGroup Batching

**ContextGroup** batches multiple frames that share the same target state and context:

```dart
final class ContextGroup {
  ContextGroup(this.state, this.context);
  
  final State state;
  final Context context;
  
  // Batch mark accumulation
  LazyGlushList<Mark>? _single;      // First mark
  List<LazyGlushList<Mark>>? _batch; // Multiple marks (lazy list)
  
  // Shared BSPPF node (first-write wins)
  SppfNode? sppfNode;
  
  // Label stacks (first-write wins)
  OpenLabel? openLabels;
  ClosedLabel? closedLabels;
  
  LazyGlushList<Mark> get mergedMarks {
    if (_batch case var batch?) {
      return _buildBalanced(batch, 0, batch.length);
    }
    return _single ?? const LazyGlushList<Mark>.empty();
  }
  
  void addMarks(LazyGlushList<Mark> marks) {
    if (_single == null && _batch == null) {
      _single = marks;  // First mark: store directly
      return;
    }
    if (_batch == null) {
      _batch = [_single!, marks];  // Switch to list mode
      _single = null;
    } else {
      _batch!.add(marks);  // Append to batch
    }
  }
}
```

### Three States

1. **Initial**: No marks received yet (`_single == null && _batch == null`)
2. **Single Mark**: One mark received (`_single != null && _batch == null`)
3. **Batch**: Multiple marks received (`_batch != null`)

### Mark Addition Flow

```
addMarks(mark1):
  _single = mark1
  _batch = null

addMarks(mark2):
  _batch = [_single, mark2]
  _single = null

addMarks(mark3):
  _batch.add(mark3)
  → _batch = [mark1, mark2, mark3]
```

---

## Two-Tier Strategy

**Problem**: Context equality checks are expensive because they involve full struct comparison across multiple fields (caller, arguments, predicates, captures, etc.).

**Solution**: Two-tier system with fast and slow paths based on context complexity.

### Fast Path: Simple Contexts

For "simple" contexts (no predicates, captures, or arguments), use bit-packed integer keys:

```dart
if (nextContext.isSimple) {
  var packedId = 
    (nextContext.caller.uid << 32) |  // Caller ID (upper bits)
    (state.id << 8) |                 // State ID (middle bits)
    (nextContext.minPrecedenceLevel ?? 0xFF); // Precedence (lower bits)
  
  // Check existing group
  var group = _currentFrameGroupsInt[packedId];
  if (group != null) {
    group.addMarks(marks);      // Merge into existing batch
    group.addSppfNode(sppfNode);
    return;
  }
  
  // Create new group
  _currentFrameGroupsInt[packedId] = ContextGroup(state, nextContext)
    ..addMarks(marks)
    ..addSppfNode(sppfNode);
}
```

**Performance**: Single integer hash lookup (O(1)).

**Conditions for "simple"**:
- No active predicates (`predicateStack.isEmpty`)
- No data-captured labels (`captures.isEmpty`)
- No rule arguments (`arguments.isEmpty`)

### Slow Path: Complex Contexts

For complex contexts, use the full `Context` as key:

```dart
var key = ComplexContextKey(state, nextContext);

// Check existing group
var group = _currentFrameGroupsComplex[key];
if (group != null) {
  group.addMarks(marks);
  group.addSppfNode(sppfNode);
  group.addOpenLabels(openLabels);
  group.addClosedLabels(closedLabels);
  return;
}

// Create new group
_currentFrameGroupsComplex[key] = ContextGroup(state, nextContext)
  ..addMarks(marks)
  ..addSppfNode(sppfNode)
  ..addOpenLabels(openLabels)
  ..addClosedLabels(closedLabels);
```

**Performance**: Hash-based map lookup with full context comparison.

**When used**:
- Active predicates present
- Captured labels present
- Rule arguments present
- Captures at current position

### Two Maps

```dart
class StepWorklist {
  final Map<int, ContextGroup> _currentFrameGroupsInt = {};      // Fast
  final Map<Object, ContextGroup> _currentFrameGroupsComplex = {}; // Slow
  
  final Map<int, ContextGroup> _nextFrameGroupsInt = {};         // Fast (next position)
  final Map<Object, ContextGroup> _nextFrameGroupsComplex = {};  // Slow (next position)
}
```

---

## Fast Path: Simple Contexts

### Location

[lib/src/parser/common/step.dart:688-710](../lib/src/parser/common/step.dart#L688-L710)

### Bit-Packing Strategy

```
Bit layout (64-bit):
┌─────────────────────┬─────────────┬───────────────┐
│   Caller UID        │  State ID   │  Precedence   │
│   (32 bits)         │  (24 bits)  │  (8 bits)     │
└─────────────────────┴─────────────┴───────────────┘
```

### Performance Characteristics

- **Hash Computation**: Single integer (no hashing needed)
- **Equality Check**: Integer equality (O(1))
- **Memory**: Single 64-bit value
- **Common Case**: Most grammars without predicates or advanced features

### Example

```dart
// Simple context: position 5, caller is main, state 10
var packedId = 
  (mainCallerUid << 32) |  // Main caller ID
  (10 << 8) |              // State 10
  (0xFF);                  // No precedence constraint

// Exact same context again
var packedId2 = 
  (mainCallerUid << 32) |
  (10 << 8) |
  (0xFF);

assert(packedId == packedId2);  // Batching occurs!
```

---

## Slow Path: Complex Contexts

### Location

[lib/src/parser/common/step.dart:720-745](../lib/src/parser/common/step.dart#L720-L745)

### Full Context Key

```dart
class ComplexContextKey {
  final State state;
  final Context context;
  
  @override
  int get hashCode => Object.hash(
    state.id,
    context.caller,
    context.arguments,
    context.captures,
    context.predicateStack,
    context.position,
    context.minPrecedenceLevel,
    context.precedenceLevel,
  );
  
  @override
  bool operator ==(Object other) =>
    other is ComplexContextKey &&
    state.id == other.state.id &&
    context == other.context;
}
```

### When Complex Contexts Are Used

```dart
// Grammars with predicates
rule = &('a' 'b') 'a' >> 'c'  // Active predicate

// Grammars with captures
rule = $foo:pattern           // Captured label

// Grammars with parameters
rule(x, y) = ...              // Arguments

// Grammars with captures at current position
pattern = label:(...) ...
```

---

## Balanced Tree Merging

When multiple marks are batched, they're merged into a **balanced binary tree** to prevent degenerate left-skewed chains.

### The Problem

If marks were merged left-associatively:

```
mark1 >> mark2 >> mark3 >> mark4
→ (((mark1 >> mark2) >> mark3) >> mark4)  ← Left-skewed chain!
```

This creates O(n) depth for n marks, leading to O(n) traversal time later.

### The Solution

Build a balanced tree instead:

```dart
static LazyGlushList<Mark> _buildBalanced(List<LazyGlushList<Mark>> items, int start, int end) {
  var len = end - start;
  if (len == 0) return const LazyGlushList<Mark>.empty();
  if (len == 1) return items[start];
  if (len == 2) return LazyGlushList.branched(items[start], items[start + 1]);
  
  var mid = start + (len >> 1);
  return LazyGlushList.branched(
    _buildBalanced(items, start, mid),      // Left half
    _buildBalanced(items, mid, end),        // Right half
  );
}
```

### Result

```
[mark1, mark2, mark3, mark4]
→ Branched(
    Branched(mark1, mark2),
    Branched(mark3, mark4)
  )  ← Balanced tree!
```

**Depth**: O(log n) instead of O(n)

### Example

For 4 marks:

```
Input: [m1, m2, m3, m4]

Step 1: Split at mid = 2
  Left: _buildBalanced([m1, m2], 0, 2)
    → Branched(m1, m2)
  Right: _buildBalanced([m3, m4], 2, 4)
    → Branched(m3, m4)

Final: Branched(Branched(m1, m2), Branched(m3, m4))
```

---

## Batching Modes

Batching operates in two modes based on whether the action consumes a token.

### Current-Position Batching

Same-position epsilon transitions batch into `_currentFrameGroups`:

- Immediate state exploration (no token consumed)
- Batches deduplicate redundant epsilon paths
- Processed immediately via work queue

```dart
// Epsilon action (doesn't consume token)
void _processEpsilon(State state, Context context, ...) {
  var group = _currentFrameGroups[key];
  if (group != null) {
    group.addMarks(marks);  // Merge into existing group
    return;
  }
  // Or create new group...
}
```

### Next-Position Batching

Token-consuming actions batch into `_nextFrameGroups`:

- Token transition actions deferred until finalization
- Avoids interleaving same-position closure with next-position work
- Finalized together in `finalize()` method

```dart
// Token action (consumes token)
void _processToken(State state, Context context, ...) {
  var group = _nextFrameGroups[key];
  if (group != null) {
    group.addMarks(marks);  // Merge into next-position batch
    return;
  }
  // Or create new group...
}

void finalize() {
  for (var nextGroup in _nextFrameGroupsInt.values.followedBy(_nextFrameGroupsComplex.values)) {
    _processNextGroup(nextGroup);  // Convert to frames for next position
  }
  _nextFrameGroupsInt.clear();
  _nextFrameGroupsComplex.clear();
}
```

---

## Current-Position vs. Next-Position

### Distinction

| Aspect | Current-Position | Next-Position |
|--------|------------------|---------------|
| **Token Consumed** | No (ε transitions) | Yes (token actions) |
| **Storage** | `_currentFrameGroups*` | `_nextFrameGroups*` |
| **Processing** | Immediate | Deferred to `finalize()` |
| **Purpose** | Immediate closure | Batch work for next position |

### Why Separate?

**Interleaving Problem**: If current-position and next-position frames were processed together, the order would matter:

```
Current-position frame 1 (ε)
  → generates next-position frame A
Current-position frame 2 (ε)
  → generates next-position frame B
Next-position frame A
  → generates current-position frame 3 (ε)

Without separation, frame 3 might be processed out of order.
```

**Solution**: Process all current-position frames to closure before moving to next position:

```
1. Process all current-position frames (until empty)
2. Finalize all next-position batches
3. Move to next token
```

This ensures deterministic, ordered processing.

---

## Confusion Points Clarified

### 1. Batching vs. Grouping

The term "grouping" is sometimes used for `ContextGroup` (the batching mechanism) and sometimes for context-equivalence classes (frames with identical context).

**Clarification**:
- **ContextGroup**: The `ContextGroup` class; holds batched marks, SPPF node, labels
- **Context Equivalence**: Two frames with identical `Context` objects are equivalent
- **Batching**: Merging equivalent frames into a single `ContextGroup`

### 2. Mark Merging Timing

Marks are merged **lazily** via `LazyGlushList.branched()` only when `mergedMarks` is accessed, not when `addMarks()` is called.

```dart
// Calling addMarks does NOT merge
group.addMarks(marks1);  // Just appends to list
group.addMarks(marks2);  // Just appends to list

// Accessing mergedMarks triggers lazy evaluation
var merged = group.mergedMarks;  // Now balanced tree is built
```

**Why Lazy?**:
- Defers work until needed (if marks are never accessed, no overhead)
- Allows more marks to arrive before deciding merge strategy
- Reduces peak memory during parsing

### 3. SPPF Node "First-Write"

The SPPF node stored in a `ContextGroup` is the **first non-null** one encountered.

```dart
void addSppfNode(SppfNode? node) {
  sppfNode ??= node;  // Only set if currently null
}
```

**Why First-Write?**:
- All frames in a context group parse the same rule over the same span
- Via `SppfTable` deduplication, they all reach the same node anyway
- Storing only the first avoids redundant entries
- All subsequent frames in the group will add families to this node

### 4. Label Stack Sharing

Open and closed label stacks are shared with first-write semantics:

```dart
void addOpenLabels(OpenLabel? labels) {
  openLabels ??= labels;  // Only set if currently null
}
```

**Why First-Write?**:
- All frames in the group execute the same rule
- Label stacks accumulate in the same order
- Only the first frame's labels are semantically significant
- Reduces memory footprint

---

## Why Context Batching Matters

### 1. Deduplication

Avoids re-exploring identical (state, context) pairs:

```
Without batching:
  Frame 1 reaches State 5, Context C → explore State 5
  Frame 2 reaches State 5, Context C → explore State 5 AGAIN ✗

With batching:
  Frame 1 reaches State 5, Context C → explore State 5
  Frame 2 reaches State 5, Context C → batched with Frame 1 ✓
```

### 2. Mark Efficiency

Lazy branching defers structural merging until needed:

```dart
group.addMarks(marks1);  // O(1) append
group.addMarks(marks2);  // O(1) append
group.addMarks(marks3);  // O(1) append

var merged = group.mergedMarks;  // O(log n) balanced merge when accessed
```

### 3. SPPF Amortization

Multiple derivations of the same span add families to a single shared node:

```dart
// All three frames reach SymbolNode(S, 0, 5)
frame1.sppfNode = symbolNode;
frame2.sppfNode = symbolNode;
frame3.sppfNode = symbolNode;

// Each frame adds its derivation as a family
symbolNode.families = [family1, family2, family3];
```

### 4. Scalability

Enables handling ambiguous grammars without exponential state explosion:

```
Grammar: S → S S | 'a'
Input: "aaaaa"

Without batching: ~1000+ frames explored
With batching: ~5-10 context groups
```

---

## Integration Example

Here's how context batching works end-to-end:

### Step 1: Action Fires

Parser consumes token 'a' at position 3, transitioning to State 7.

```dart
// Inside step() method
var nextContext = context.advancePosition(4);
var marks = LazyGlushList.push(currentMarks, Mark("token_a"));
var sppfNode = frame.sppfNode;
```

### Step 2: Check for Existing Group

```dart
if (nextContext.isSimple) {
  var packedId = (nextContext.caller.uid << 32) | (7 << 8) | 0xFF;
  var group = _nextFrameGroupsInt[packedId];
  
  if (group != null) {
    // Found existing group for same context
    group.addMarks(marks);
    group.addSppfNode(sppfNode);
    return;  // No new work generated
  }
}
```

### Step 3: Create Group (if new)

```dart
_nextFrameGroupsInt[packedId] = ContextGroup(State(7), nextContext)
  ..addMarks(marks)
  ..addSppfNode(sppfNode);
```

### Step 4: Finalization

At end of current position:

```dart
void finalize() {
  for (var nextGroup in _nextFrameGroupsInt.values) {
    // Convert group to frame for next position
    var mergedMarks = nextGroup.mergedMarks;  // Lazy merge happens here
    var frame = Frame(
      nextGroup.context,
      mergedMarks,
      sppfNode: nextGroup.sppfNode,
    );
    nextFrames.add(frame);
  }
}
```

### Result

- All frames with identical context/state are merged into one frame
- Marks from all frames are lazily combined
- SPPF node is shared
- Single frame advances to next position

---

## Summary

Context batching is a two-tier optimization that groups equivalent frames to avoid re-exploring identical parser states. By using bit-packed integer keys for simple contexts and hash-based maps for complex ones, Glush minimizes comparison overhead while maximizing deduplication. Marks are merged lazily into balanced trees, and SPPF nodes are shared via first-write semantics. The result is efficient, deterministic exploration of ambiguous grammars without exponential state explosion.
