# SPPF (Shared Packed Parse Forest): A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Overview](#overview)
3. [Node Hierarchy](#node-hierarchy)
4. [Terminal Nodes](#terminal-nodes)
5. [Epsilon Nodes](#epsilon-nodes)
6. [Intermediate Nodes](#intermediate-nodes)
7. [Symbol Nodes](#symbol-nodes)
8. [SPPF Family](#sppf-family)
9. [Deduplication via SppfTable](#deduplication-via-sppftable)
10. [Key Features & Mechanisms](#key-features--mechanisms)
11. [Why SPPF is Important](#why-sppf-is-important)
12. [Limitations](#limitations)

---

## Core Concept

A **Shared Packed Parse Forest (SPPF)** is a compact, graph-based representation of all possible parse trees for an ambiguous grammar. Unlike traditional parsers that fail on ambiguity or produce only one parse, Glush builds a BSPPF (Binarized Shared Packed Parse Forest) that represents multiple derivations efficiently by sharing common substructures.

### Location & Key Files

- **Core Definition**: [lib/src/core/sppf.dart](../lib/src/core/sppf.dart)
- **Deduplication Table**: [lib/src/parser/common/sppf_table.dart](../lib/src/parser/common/sppf_table.dart)
- **Frame Integration**: [lib/src/parser/common/frame.dart](../lib/src/parser/common/frame.dart)

---

## Overview

The fundamental insight behind SPPF is **structural sharing**: when two different parse derivations produce identical substructures (same rule over same span), they point to the same node object in memory. This prevents the combinatorial explosion that would occur if each derivation created its own tree.

### How It Works

1. **Forest as a DAG**: Rather than building separate parse trees for each derivation, SPPF represents all derivations as a directed acyclic graph (DAG)
2. **Nodes as Keys**: Nodes are identified by their (type, start, end) — nodes with identical keys refer to the same object
3. **Multiple Derivations**: Different derivations of the same node are stored as separate "family" entries within that node
4. **Lazy Mark Association**: Semantic information (marks, labels) is attached separately and merged lazily

---

## Node Hierarchy

All SPPF nodes inherit from the sealed class `SppfNode`:

```
SppfNode (abstract)
├── TerminalNode         (leaf: single input token at position)
├── EpsilonNode          (leaf: zero-width derivation ε)
└── Interior Nodes (shared)
    ├── IntermediateNode (state slot + span; multiple derivations)
    ├── SymbolNode       (complete rule derivation; span)
    └── SppfFamily       (binary split: left + right)
```

---

## Terminal Nodes

**TerminalNode** represents a single consumed input token.

**Location**: [lib/src/core/sppf.dart:26](../lib/src/core/sppf.dart#L26-L35)

```dart
class TerminalNode extends SppfNode {
  const TerminalNode(this.position);
  final int position;

  @override int get start => position;
  @override int get end => position + 1;
}
```

### Properties

- Represents a single character/token at a specific position
- Keyed by input position (each position has at most one TerminalNode)
- Immutable with identity-based deduplication
- Leaf nodes in the parse forest

### Example

For input "abc":

- `TerminalNode(0)` represents 'a'
- `TerminalNode(1)` represents 'b'
- `TerminalNode(2)` represents 'c'

---

## Epsilon Nodes

**EpsilonNode** represents zero-width derivations (where nothing is consumed).

**Location**: [lib/src/core/sppf.dart:37](../lib/src/core/sppf.dart#L37-L50)

### Properties

- Represents ε (epsilon) productions that match nothing
- Keyed by input position (the position where ε matched)
- Shared across all ε parses at the same position
- Leaf nodes in the parse forest

### Example

For a rule like `optional = 'x' | ε`, the ε alternative produces an `EpsilonNode`.

### Why Position-Keyed?

Epsilon nodes are keyed by position because:

1. An ε derivation doesn't advance the input cursor
2. Two ε productions at the same position represent the same event
3. Sharing ε nodes reduces memory footprint

---

## Intermediate Nodes

**IntermediateNode** represents partial parse progress within a rule.

**Location**: [lib/src/core/sppf.dart:100](../lib/src/core/sppf.dart#L100-L145)

### Key Concept

In Glush, the state machine is **already binarized**: a rule like `S = A B C` compiles implicitly as `S = ((A B) C)` through a chain of states. Each state slot ID maps to an `IntermediateNode`, representing accumulation up to that point.

```dart
class IntermediateNode extends SppfNode {
  IntermediateNode(this.slotId, this.start, this.end);

  final int slotId;          // State machine state ID
  @override final int start;
  @override final int end;

  SppfFamily? _singleFamily; // Optimized single-derivation case
  List<SppfFamily>? _multipleFamilies; // Ambiguous case

  void addFamily(SppfNode? left, SppfNode right) {
    // Deduplicates by identity; multiple derivations create separate entries
  }
}
```

### Triple Key: (slotId, start, end)

- **slotId**: Which state machine state (rule slot)
- **start**: Where the rule was invoked
- **end**: Current parse position

All frames reaching the same (slotId, start, end) reuse the same `IntermediateNode`.

### Families

When multiple derivations reach the same `IntermediateNode`, each adds a distinct `SppfFamily` entry:

```dart
void addFamily(SppfNode? left, SppfNode right) {
  if (_singleFamily == null) {
    _singleFamily = SppfFamily(left, right);  // First derivation
    return;
  }

  // Switch to multi-derivation mode
  if (_multipleFamilies == null) {
    _multipleFamilies = [_singleFamily!];
    _singleFamily = null;
  }

  _multipleFamilies!.add(SppfFamily(left, right));  // Second+ derivations
}
```

---

## Symbol Nodes

**SymbolNode** represents a complete derivation of a grammar rule.

**Location**: [lib/src/core/sppf.dart:155](../lib/src/core/sppf.dart#L155-L180)

### Key Concept

When a rule completes (a `ReturnAction` fires), the parser creates or reuses a `SymbolNode` representing the completed derivation. All frames completing the same rule over the same span share this node.

```dart
class SymbolNode extends SppfNode {
  SymbolNode(this.ruleSymbol, this.start, this.end);

  final PatternSymbol ruleSymbol;
  @override final int start;
  @override final int end;

  List<SppfNode?> families = [];  // One entry per derivation
  Map<String, List<(int start, int end)>>? _labelMap; // Data-driven labels
}
```

### Triple Key: (ruleSymbol, start, end)

- **ruleSymbol**: Which grammar rule completed
- **start**: Start position of the rule invocation
- **end**: End position of the rule invocation

### Label Index

`SymbolNode` maintains a map of labels (structural annotations) that were captured during derivation:

```dart
Map<String, List<(int start, int end)>>? _labelMap;

// Query: find all "name" labels closed during this derivation
var spans = symbolNode.labelFor("name");  // O(1) lookup
```

This enables **data-driven parsing**: post-parse queries for specific labeled substructures without tree traversal.

---

## SPPF Family

**SppfFamily** represents one binary split within a node.

**Location**: [lib/src/core/sppf.dart:82](../lib/src/core/sppf.dart#L82-L100)

### Binarization Representation

```dart
class SppfFamily {
  const SppfFamily(this.left, this.right);

  final SppfNode? left;   // Accumulated prefix (previous IntermediateNode or null for ε)
  final SppfNode? right;  // Rightmost child just completed
}
```

### Example

For a rule with three alternatives A, B, C:

```
Before binarization:
  Node[start..end]
    ├─ A[start..i]
    ├─ B[i..j]
    └─ C[j..end]

After binarization (implicit via state machine):
  IntermediateNode(slot0, start, i)        ← after A
    └─ SppfFamily(null, A)

  IntermediateNode(slot1, start, j)        ← after A, B
    └─ SppfFamily(IntermediateNode(slot0), B)

  SymbolNode(Rule, start, end)             ← after A, B, C
    └─ SppfFamily(IntermediateNode(slot1), C)
```

### Why Binary?

- State machine is already binarized internally
- Each state slot produces exactly one right-side child
- Left side accumulated from previous state
- No need for explicit re-binarization

---

## Deduplication via SppfTable

The **SppfTable** is the central authority for node creation and deduplication. All SPPF nodes go through it to ensure sharing.

**Location**: [lib/src/parser/common/sppf_table.dart](../lib/src/parser/common/sppf_table.dart)

### Design Pattern

The table maintains four key maps:

- **Terminals**: `Map<int, TerminalNode>` keyed by position
- **Epsilons**: `Map<int, EpsilonNode>` keyed by position
- **Intermediate**: `Map<int, IntermediateNode>` (fast) + `Map<Object, IntermediateNode>` (complex) keyed by `(slotId, start, end)`
- **Symbols**: `Map<int, SymbolNode>` (fast) + `Map<Object, SymbolNode>` (complex) keyed by `(ruleSymbol, start, end)`

### Fast vs. Slow Path

Fast path uses bit-packing for common cases; complex path uses `Object.hash`:

```dart
class SppfTable {
  final Map<int, TerminalNode> _terminals = {};
  final Map<int, EpsilonNode> _epsilons = {};
  final Map<int, IntermediateNode> _intermediateSimple = {};
  final Map<Object, IntermediateNode> _intermediateComplex = {};

  IntermediateNode intermediate(int slotId, int start, int end) {
    if (slotId < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      // Fast path: bit-pack into single int
      var key = (slotId << 32) | (start << 16) | end;
      return _intermediateSimple[key] ??= IntermediateNode(slotId, start, end);
    }
    // Slow path: use Object.hash for complex keys
    var key = Object.hash(slotId, start, end);
    return _intermediateComplex[key] ??= IntermediateNode(slotId, start, end);
  }
}
```

### Deduplication in Action

```dart
// Frame A reaches state slot 5, span [0..10]
var nodeA = sppfTable.intermediate(5, 0, 10);

// Frame B (different derivation) reaches the same state/span
var nodeB = sppfTable.intermediate(5, 0, 10);

assert(identical(nodeA, nodeB)); // Same object in memory!
```

### Implication: Multiple Derivations via Families

```dart
// Frame A adds its derivation
nodeA.addFamily(leftA, rightA);

// Frame B adds a different derivation to the same node
nodeB.addFamily(leftB, rightB);

// Result: nodeA (same as nodeB) now has 2 families
// Both derivations are recorded in a single SymbolNode!
```

---

## Key Features & Mechanisms

### 1. Automatic Binarization

Glush's state machine is **already binarized**: `S = A B C` compiles implicitly as `S = ((A B) C)` through a chain of states.

Each `IntermediateNode` maps directly to a state machine slot (state ID), requiring no explicit re-binarization. This makes SPPF construction straightforward: each action produces at most one new node.

### 2. Node Sharing

Two parse paths that produce the same node (same type, start, end) **reuse the same object**. This prevents exponential explosion:

**Without sharing**: S → S S | 'a' with input "aaaaa"

```
Time: O(2^n) where n = input length
Space: Exponential trees
```

**With sharing**: Multiple derivations collapse into families within shared nodes

```
Time: O(n³) - cubic in input length
Space: O(n²) - polynomial deduplication
```

### 3. Multiple Derivations via Families

When multiple derivations of the same rule span reach a `SymbolNode` or `IntermediateNode`, each adds a distinct `SppfFamily` entry:

```dart
// Frame 1 completes S over span [0..5]
frame1.sppfNode = symbolNode;  // symbolNode = SymbolNode(S, 0, 5)

// Frame 2 (different derivation) completes S over [0..5]
// → reuses same symbolNode, adds new family entry
symbolNode.addFamily(newLeft, newRight);  // second derivation

// Result: symbolNode.families has 2 entries
```

### 4. Lazy Evaluation with Marks

The SPPF is paired with **marks** (a lazy tree of annotations). The parser accumulates marks in frames, which are merged into the SPPF structure only when needed.

```dart
class Frame {
  final SppfNode? sppfNode;      // BSPPF node (first-write wins)
  final LazyGlushList<Mark> marks; // Lazy mark forest
}
```

**Timing**:

- Marks are accumulated during parsing
- Mark trees are merged lazily via `LazyGlushList.branched()`
- Full evaluation only occurs post-parse when needed

### 5. Label Index for Data-Driven Parsing

`SymbolNode` maintains a label map for structural labels (e.g., `name:pattern`), enabling O(1) queries post-parse:

```dart
// In SymbolNode
Map<String, List<(int start, int end)>>? _labelMap;

// Post-parse query: find all "name" labels
var spans = symbolNode.labelFor("name");  // O(1) lookup
// Returns: [(start1, end1), (start2, end2), ...]
```

This is critical for grammar-driven data extraction without post-traversal.

---

## Why SPPF is Important

### 1. Handles Ambiguity

Represents all parse trees without duplication or enumeration:

```
Grammar: S → S S | 'a'
Input: "aaa"

Possible derivations: 2 (Catalan number C_2)
With SPPF:
  SymbolNode(S, 0, 3)
    ├─ Family 1: S[0..1] S[1..3]
    └─ Family 2: S[0..2] S[2..3]
```

### 2. Prevents Exponential Explosion

Highly ambiguous grammars remain tractable:

```
Without SPPF: "aaaaa" → 42 different parse trees
With SPPF: 5 SymbolNodes, families tracked in each
```

### 3. Efficient Memory

Structural sharing keeps memory usage polynomial instead of exponential.

### 4. Composable

Multiple derivations can be enumerated and evaluated lazily:

```dart
forest.allMarkPaths()  // Enumerate all derivations
  .evaluate()          // Flatten when needed
```

### 5. Data-Driven Parsing

Label index enables grammar-based data extraction:

```dart
symbolNode.labelFor("identifier")  // O(1) query
```

---

## Limitations

### 1. Enumeration Cost

While SPPF is compact, enumerating all derivations is still exponential in the worst case:

```
Grammar: S → S S | 'a'
Input: "aaaaa"
Derivations to enumerate: C_n (Catalan number) ≈ exponential
```

### 2. Label Overhead

Label tracking requires additional bookkeeping during parsing:

```dart
// Label stacks must be maintained per frame
// Indexed into SymbolNode on rule completion
```

### 3. Complex Semantics

Evaluating overlapping or nested labels requires careful mark processing:

```dart
// E.g., label1: (label2: pattern1 pattern2) pattern3
// Mark tree must correctly track scope boundaries
```

### 4. Cycles in Grammars

Left-recursive rules require special handling to avoid infinite loops. Glush uses the GSS (Graph Shared Stack) to detect and handle cycles.

---

## Summary

The SPPF is the foundation of Glush's approach to ambiguous parsing. By representing multiple derivations as families within shared nodes, Glush avoids the combinatorial explosion of traditional parsers while maintaining access to all possible parses. Combined with lazy mark evaluation and label indexing, SPPF enables efficient, data-driven parsing of highly ambiguous grammars.
