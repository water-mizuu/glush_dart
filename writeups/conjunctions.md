# Conjunctions in Glush: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Semantics vs Syntax](#semantics-vs-syntax)
3. [Pattern-Level Representation](#pattern-level-representation)
4. [Grammar Syntax](#grammar-syntax)
5. [Matching Behavior](#matching-behavior)
6. [Span Constraints](#span-constraints)
7. [Mark and Label Recovery](#mark-and-label-recovery)
8. [Conjunction with Ambiguity](#conjunction-with-ambiguity)
9. [Mathematical Properties](#mathematical-properties)
10. [Use Cases](#use-cases)
11. [Advanced Scenarios](#advanced-scenarios)
12. [Implementation Details](#implementation-details)

---

## Core Concept

Conjunctions in Glush enable **pattern intersection** through the AND operator (`&`). A conjunction of two patterns matches the **intersection** of their languages—meaning input must simultaneously satisfy both patterns on the **exact same span**.

### Primary Purpose

Conjunctions serve critical functions in advanced parsing:

1. **Constraint Verification**: Verify that input conforms to multiple independent specifications simultaneously
2. **Ambiguity Disambiguation**: When a parse is ambiguous, conjunctions can filter to only derivations that satisfy additional constraints
3. **Semantic Refinement**: Apply a "filter" pattern that verifies properties without changing what is consumed

### Key Property: Span Synchronization

The defining characteristic of conjunctions is that **both patterns must consume exactly the same span of input**. This is fundamentally different from sequencing (`A >> B`), where patterns consume different parts:

```dart
// Sequencing: A consumes [0:i), B consumes [i:j)
A >> B

// Conjunction: both A and B consume the same span [i:j)
A & B
```

If one pattern consumes "ab" and the other consumes "a", the conjunction fails because they don't cover the same span.

### Distinction from Negation and Predicates

Unlike predicates (`&pattern`, `!pattern`) which are zero-width assertions, conjunctions are **span-consuming**:

- **Predicates**: Check a condition at a position without consuming input
- **Conjunctions**: Both patterns must match and consume the same input

Example:

```dart
&'a' 'a'    // Predicate: check for 'a' (zero-width), then consume 'a'
'a' & 'a'   // Conjunction: both must match 'a' on exact same span
```

---

## Semantics vs Syntax

### What "Matching Both Patterns" Means

When evaluating `A & B` against input:

1. **Try to match A** over various spans starting at the current position
2. **Try to match B** starting from the same position
3. **Find all pairs (A-derivation, B-derivation)** that consume exactly the same span
4. **Produce conjunction marks** for each successful pair
5. **Fail** if no pair exists

### Rendezvous Point

The "rendezvous point" is the **end position** where both patterns must agree:

```
Input: "a b c"
       0 1 2 3

Conjunction (A & B) starts at position 0:
  Pattern A: tries all possible endings (position 1, 2, 3, etc.)
  Pattern B: tries all possible endings (position 1, 2, 3, etc.)

  For each position where BOTH A and B can match [0, pos),
  the conjunction succeeds at that position.
```

---

### Location & Key Files

- **Core Pattern**: [lib/src/core/patterns.dart:2471-2515](../lib/src/core/patterns.dart#L2471-L2515)
- **Rendezvous Logic**: [lib/src/parser/common/step.dart:117-178](../lib/src/parser/common/step.dart#L117-L178)
- **Conjunction Tracker**: [lib/src/parser/common/trackers.dart:68-83](../lib/src/parser/common/trackers.dart#L68-L83)

---

## Pattern-Level Representation

### Core Class

In the Glush implementation, conjunctions are represented through the `Conj` class in [lib/src/core/patterns.dart](lib/src/core/patterns.dart):

```dart
class Conj extends Pattern {
  Conj(Pattern left, Pattern right)
      : left = left.consume(),
        right = right.consume();

  final Pattern left;
  final Pattern right;

  @override
  bool singleToken() => left.singleToken() && right.singleToken();

  @override
  bool match(int? token) => left.match(token) && right.match(token);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var leftEmpty = left.calculateEmpty(emptyRules);
    var rightEmpty = right.calculateEmpty(emptyRules);
    var result = leftEmpty && rightEmpty;
    setEmpty(result);
    return result;
  }

  @override
  bool isStatic() => left.isStatic() && right.isStatic();

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  Conj copy() => Conj(left, right);

  @override
  Pattern invert() => left.invert() | right.invert();  // De Morgan's law

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  String toString() => "conj($left, $right)";
}
```

**Key Method - `match(int? token)`**:

The `match` method implements **token-level intersection**:

```dart
bool match(int? token) => left.match(token) && right.match(token);
```

A token matches a conjunction if and only if it matches **both** constituent patterns.

---

## Grammar Syntax

### Conjunction Operator

Conjunctions are formed using the `&` (AND) operator:

**Basic Syntax**:

```dart
pattern1 & pattern2
```

### Precedence

The `&` operator has **higher precedence than alternation** (`|`) but **lower precedence than sequence** (`>>`):

```dart
// Parsing as: (a >> b) & (a >> c) | d
a b & a c | d

// Equivalent to:
(a >> b & a >> c) | d
```

To force different grouping, use parentheses:

```dart
// Explicit grouping
(a | b) & (c | d)

// Three-way conjunction
a & b & c

// Nested conjunction
(a & b) & c
```

### Grammar DSL Examples

**String Pattern Conjunction**:

```dart
rule = 'ab' & [ab]{2}
```

Matches exactly "ab" (both patterns agree on this input).

**Rule Conjunction**:

```dart
rule = pattern1 & pattern2

pattern1 = [a-z]+
pattern2 = [a-d]+

// Matches input that is both:
// - One or more letters (pattern1)
// - One or more letters from [a-d] (pattern2)
// This effectively matches one or more [a-d]
```

**Labeled Conjunction**:

```dart
rule = l1:pattern1 & l2:pattern2

pattern1 = 'a' ('b' | 'b')
pattern2 = 'a' 'b'

start = rule
```

Both labels are captured in the result, allowing separate evaluation of each branch.

---

## Matching Behavior

### Single Token Conjunctions

When both patterns match single tokens, the conjunction is straightforward:

```dart
'a' & [a-z]
```

Matches only if input contains 'a' (which is both exactly 'a' AND in [a-z]).

### Multi-Token Conjunctions

For patterns consuming multiple tokens, conjunction requires **both consume the exact same sequence**:

**Example**:

```dart
rule = ('a' 'b') & ('a' [a-z])
```

Matching against "ab":

1. Left pattern `'a' 'b'`matches "ab" at span [0:2)
2. Right pattern `'a' [a-z]` matches "ab" at span [0:2) (because 'b' ∈ [a-z])
3. **Both match the same span**, so conjunction succeeds

Matching against "ac":

1. Left pattern `'a' 'b'` fails at span [0:2) (expects 'b', got 'c')
2. Right pattern `'a' [a-z]` matches "ac" at span [0:2) (because 'c' ∈ [a-z])
3. **Patterns disagree on whether "ac" is valid**, so conjunction fails

### Epsilon Conjunctions

When patterns match empty input (epsilon), conjunction requires **both to match epsilon**:

```dart
rule = ('a')? & (('a'){0,1})

input: ""
```

Both patterns can match empty:

1. Left pattern `'a'?` matches epsilon
2. Right pattern `('a'){0,1}` matches epsilon
3. **Both match the same (empty) span**, so conjunction succeeds

Matching against "a":

1. Left pattern matches "a"
2. Right pattern matches "a"
3. **Both match the same span**, so conjunction succeeds

---

## Span Constraints

### Length Matching

A critical constraint is that **both patterns must produce the same-length match**. If one consumes [0:2) and the other consumes [0:3):

```dart
rule = ('a' 'b') & ('a' 'b' 'c')

input: "abc"
```

1. Left pattern matches "ab" at span [0:2)
2. Right pattern matches "abc" at span [0:3)
3. **Spans are different**, so conjunction fails at position 2

### Mismatch Length Failure

This is a common scenario:

```dart
rule = ('a' 'a') & 'a'  // "aa" vs "a"

input: "aa"
```

1. Left pattern matches "aa" (two a's)
2. Right pattern matches only one "a"
3. For the conjunction to succeed, both must cover the same span
4. **No common endpoint**, so conjunction fails

### Position-Aware Matching

Conjunctions are **aware of input position**. Two patterns can match different positions:

```dart
rule = (start_pos >> 'a') & 'a'

// After consuming tokens up to position i,
// both must match the span from i onward
```

---

## Mark and Label Recovery

When both patterns produce labeled outputs (marks), both are recovered in the result:

### Label Conjunction

```dart
rule = l1:pattern1 & l2:pattern2

pattern1 = 'x'
pattern2 = 'x'

start = rule
```

When input is "x":

1. Both patterns match "x"
2. Conjunction succeeds
3. Result contains both `l1` and `l2` labels with their matched content

### Triple Intersection

Conjunctions can be nested (chained):

```dart
rule = (l1:'a' & l2:'a') & l3:'a'

input: "a"
```

1. Inner conjunction `l1:'a' & l2:'a'` matches "a"
2. Outer conjunction with `l3:'a'` on span [0:1) succeeds
3. Result contains all three labels: `l1`, `l2`, `l3`

### Ambiguous Intersection

When one pattern is ambiguous (multiple derivations) and another is deterministic, the conjunction produces all ambiguous combinations:

```dart
rule = (l1:'x' | l2:'x') & ('x')

input: "x"
```

1. Left pattern has two derivations (via l1 or l2)
2. Right pattern has one derivation
3. Conjunction has 2 × 1 = 2 derivations (one for each combination)

---

## Conjunction with Ambiguity

### Cartesian Product of Marks

When conjunctions involve ambiguous patterns, the result is a **Cartesian product of mark sequences**:

```dart
final tree = evaluator.evaluate(outcome.rawMarks, input: "abc");
```

Possible derivation combinations:

1. (a derivation) & (c derivation)
2. (a derivation) & (d derivation)
3. (b derivation) & (c derivation)
4. (b derivation) & (d derivation)

All four combinations match, so the result contains 4 separate mark branches.

### Pre-Filtering with Conjunctions

Conjunctions can pre-filter ambiguous parses:

```dart
start = (a:expr | b:expr) & constraint

expr = ...  // Ambiguous rule
constraint = ... // Deterministic pattern
```

The conjunction automatically eliminates any `expr` derivations that don't satisfy `constraint`.

### Rendezvous Coordination

For recursive/ambiguous patterns, conjunctions synchronize at **rendezvous points**:

```dart
rule = L & R

L = 'a' L | 'x'        // Left-recursive rule
R = 'a' R | 'x'        // Right-recursive rule

input: "aaax"
```

The conjunction ensures both L and R recognize the same input, eliminating incompatible derivations.

---

## Mathematical Properties

Conjunctions in Glush follow formal properties from language theory:

### Commutativity

Conjunction is **commutative**: `A & B` is equivalent to `B & A`

```dart
('a' 'b') & ('a' [a-z])  ==  ('a' [a-z]) & ('a' 'b')
```

Both match the same language.

### Associativity

Conjunction is **associative**: `(A & B) & C` is equivalent to `A & (B & C)`

```dart
(l1:'a' & l2:'a') & l3:'a'  ==  l1:'a' & (l2:'a' & l3:'a')
```

Both produce the same parse results.

### Distributivity Over Alternation

Conjunction **distributes over alternation**: `A & (B | C)` equals `(A & B) | (A & C)`

```dart
'a' & ('a' | 'b')  ==  ('a' & 'a') | ('a' & 'b')

// Left side: 'a' must match both 'a' and ('a' | 'b')
// Right side: either ('a' matches both 'a') OR ('a' matches both 'b')
```

### De Morgan's Laws

Conjunction's interaction with negation follows De Morgan's laws:

```dart
¬(A & B)  ≡  ¬A | ¬B
¬(A | B)  ≡  ¬A & ¬B
```

This is reflected in the `invert()` method: `left.invert() | right.invert()`

### Idempotence

Conjunction is **idempotent**: `A & A` is equivalent to `A`

```dart
'a' & 'a'  ==  'a'
```

Though Glush preserves the conjunction node for consistency.

---

## Use Cases

### Constraint Validation

Verify that input satisfies multiple independent specifications:

```dart
// Must be both a valid identifier AND not a reserved word
identifier_or_keyword = identifier & !(reserved_word)

identifier = [a-zA-Z_][a-zA-Z0-9_]*
reserved_word = 'if' | 'else' | 'while' | ...
```

### Ambiguity Filtering

When a grammar is inherently ambiguous, use conjunction to filter to only valid derivations:

```dart
expression = (a:expr_path | b:expr_path) & valid_expr

expr_path = ...  // May produce multiple derivations
valid_expr = ... // Constraints on valid expressions
```

### Multi-Format Parsing

Parse input that must conform to multiple format specifications simultaneously:

```dart
// Input must be valid JSON AND match our type schema
json_value = base:json_pattern & typed:schema_pattern

json_pattern = ... // RFC 8259 JSON syntax
schema_pattern = ... // Our custom schema constraints
```

### Recursive Rendezvous

Synchronize recursive patterns:

```dart
// Both left and right recursion must consume the same input
balanced = left_expr & right_expr

left_expr = 'a' left_expr | 'x'
right_expr = 'a' right_expr | 'x'
```

### Semantic Verification

Apply semantic constraints without backtracking:

```dart
// Declaration must be well-formed AND type-consistent
declaration = decl_syntax & type_check

decl_syntax = ... // Syntactic structure
type_check = ... // Type constraints
```

---

## Advanced Scenarios

### Conjunction of Predicates

While predicates themselves are zero-width, you can use conjunction with patterns that encompass predicates:

```dart
// Pattern that includes lookahead assertions
rule = &predicate1 pattern & &predicate2 pattern

predicate1 = [a-z]
predicate2 = [0-9]
pattern = ...
```

### Nested Conjunctions

Conjunctions can be arbitrarily nested:

```dart
rule = ((a & b) & c) & (d & (e & f))
```

### Conjunction with Optional Patterns

Optional patterns may or may not match:

```dart
rule = ('a' 'b'?) & ('a' ('b')?)

input: "a"
```

1. Left pattern matches "a" (with optional 'b' not matched)
2. Right pattern matches "a" (with optional 'b' not matched)
3. Both match span [0:1), so conjunction succeeds

---

## Implementation Details

### Conjunction Tracker

During parsing, conjunctions are managed by a **ConjunctionTracker** that:

1. **Accepts completions** from both left and right patterns
2. **Matches spans**: Only pairs with identical end positions proceed
3. **Produces marks**: Combines marks from both patterns
4. **Memoizes results**: Caches successful conjunctions to avoid recomputation

### State Machine Integration

The state machine compiles conjunctions into states that:

1. **Branch** to explore both patterns
2. **Synchronize** at rendezvous points (same end position)
3. **Merge** marks from both branches
4. **Fail** if patterns never synchronize

### Performance Considerations

Conjunctions can be expensive:

- **Exploration Cost**: Must track all possible endpoints for both patterns
- **Memoization Overhead**: More states in the state machine
- **Memory Usage**: Multiple mark branches in ambiguous cases

Optimization strategies:

1. **Use negation** (`~pattern`) instead of conjunction when possible
2. **Simplify patterns** to reduce endpoints
3. **Avoid ambiguity** in conjunctions when feasible
4. **Cache**: Memoization is automatic but benefits from deterministic patterns

---

## Testing

Key test files for conjunctions:

- [conjunction_properties_test.dart](../test/parser/conjunction_properties_test.dart): Mathematical properties (commutativity, associativity, distributivity)
- [conjunction_edge_cases_test.dart](../test/parser/conjunction_edge_cases_test.dart): Complex scenarios, ambiguity, epsilon handling
- [sm_integration_test.dart](../test/parser/sm_integration_test.dart): State machine integration tests
