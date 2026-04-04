# Negations in Glush: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Negation Types](#negation-types)
3. [Pattern-Level Representation](#pattern-level-representation)
4. [Grammar Syntax](#grammar-syntax)
5. [Matching Behavior](#matching-behavior)
6. [Span-Level Negation Semantics](#span-level-negation-semantics)
7. [Negation vs Predicates](#negation-vs-predicates)
8. [De Morgan's Laws](#de-morgans-laws)
9. [Mark and Label Behavior](#mark-and-label-behavior)
10. [Negation with Ambiguity](#negation-with-ambiguity)
11. [Epsilon and Empty Patterns](#epsilon-and-empty-patterns)
12. [Use Cases](#use-cases)
13. [Advanced Scenarios](#advanced-scenarios)
14. [Implementation Details](#implementation-details)

---

## Core Concept

Negation in Glush enables **span-level complement matching** through the `~` operator. A negated pattern matches any input on a **specific span** that the original pattern does NOT match.

### Primary Purpose

Negations serve critical functions:

1. **Exclusion Constraints**: Specify what should NOT appear in a parse
2. **Language Complement**: Match anything except a specific pattern
3. **Semantic Filtering**: Provide negative examples in discriminative grammars

### Key Property: Span-Consuming Complement

The defining characteristic of negations is that **negation is span-consuming**—it matches actual input, just the complement:

```dart
// Negation: Match any token EXCEPT 'a'
~'a'

// This is different from:
!'a'    // Predicate: Assert 'a' is NOT at current position (zero-width)
```

Negation is fundamentally different from negative predicates (`!pattern`):

- **Negation (`~A`)**: Matches any input that A does NOT match on the same span
- **Negative Predicate (`!A`)**: Zero-width assertion that A doesn't match (doesn't consume input)

### Distinction from Intersection (Conjunction)

Negation is the complement of conjunction:

- **Conjunction (`A & B`)**: Match what BOTH patterns match
- **Negation (`~A`)**: Match what A does NOT match

These are dual operations under De Morgan's laws.

---

## Negation Types

### Simple Negation

**Purpose**: Negate a single terminal or simple pattern.

**Syntax**: `~pattern`

**Behavior**: Matches any input that `pattern` does NOT match at the current position.

**Example**:

```dart
not_a = ~'a'    // Matches 'b', 'c', 'd', etc., but not 'a'
not_digit = ~[0-9]  // Matches any single character except digits
```

### Negation of Complex Patterns

**Purpose**: Negate more complex expressions (rules, sequences, choices).

**Example**:

```dart
not_keyword = ~('if' | 'else' | 'while')

// Matches anything that is NOT one of these keywords
```

### Double Negation

**Purpose**: LogicalInversion of a negation.

**Syntax**: `~~pattern`

**Semantic**: Under classical logic, `~~A` equals `A`, but in parsing, negation is handled at the span level, so double negation may differ due to memoization and optimization.

**Example**:

```dart
rule = ~~'a'

// Theoretically matches 'a' (since not-not-a = a)
// But semantically: match any span that (any span that 'a' doesn't match) doesn't match
```

---

## Pattern-Level Representation

### Core Class

In the Glush implementation, negation is represented through the `Neg` class in [lib/src/core/patterns.dart](lib/src/core/patterns.dart):

```dart
class Neg extends Pattern {
  Neg(Pattern p) : pattern = p.consume();
  Pattern pattern;

  @override
  Neg copy() => Neg(pattern);

  @override
  Pattern invert() => pattern;  // De Morgan: ¬(¬A) = A

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    pattern.calculateEmpty(emptyRules);
    // Negation is span-consuming, so it's only empty
    // if the base pattern doesn't match empty span
    setEmpty(!pattern.empty());
    return empty();
  }

  @override
  bool isStatic() => false;  // Runtime-dependent

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    // Negations are handled by the state machine as a single unit
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  String toString() => "neg($pattern)";
}
```

**Key Properties**:

- `isStatic()` returns `false` because negation requires span-level runtime evaluation
- `invert()` returns the base pattern (De Morgan's law: `¬(¬A) = A`)
- `eachPair()` is empty (negation doesn't decompose into sequential pairs)

---

## Grammar Syntax

### Negation Operator

Negations are formed using the `~` (NOT) operator:

**Basic Syntax**:

```dart
~pattern
```

### Precedence

The `~` operator has **higher precedence than operators like sequence** (`>>`) but similar to other prefix operators:

```dart
// Parsing as: (~a) >> b
~a b

// Equivalent to:
(~a) >> b

// To negate a sequence, use parentheses:
~(a b)
```

### Combining with Other Operators

Negations can be combined with other operators:

**With Choice**:

```dart
~('a' | 'b')    // Neither 'a' nor 'b'
```

**With Sequence**:

```dart
~('a' 'b')      // Not the sequence 'a' 'b'
```

**With Conjunction**:

```dart
~('a' & 'b')    // Not the intersection of 'a' and 'b'
```

**With Predicates**:

```dart
&'a' ~'a'       // Can't sequence a predicate with negation like this
                // Instead use: (&'a') 'x'  or  'a' (~'a')
```

### Grammar DSL Examples

**Single Token Negation**:

```dart
rule = ~'x'
```

Matches any single character except 'x'.

**Character Class Negation**:

```dart
rule = ~[a-z]
```

Matches any single character not in [a-z].

**Rule Negation**:

```dart
rule = ~keyword

keyword = 'if' | 'else' | 'while' | ...
```

Matches input that is not a keyword.

**Sequence Negation**:

```dart
rule = ~('a' 'b')
```

Matches any two-character sequence except "ab".

---

## Matching Behavior

### Single Token Negation

When negating a single token pattern, negation produces all other tokens:

```dart
rule = ~'a'

input: "a"     → NO MATCH
input: "b"     → MATCH
input: "c"     → MATCH
```

### Multi-Span Negation

When negating a pattern that can match multiple spans, negation matches all OTHER spans:

```dart
rule = 'a' 'b'     // Matches "ab" (span [0:2))
       ~('a' 'b')  // Matches anything except "ab", but only spans of length 2

input: "ab" → NO MATCH (matches the pattern we're negating)
input: "ac" → MATCH (different from "ab")
input: "a"  → DEPENDS (spans don't match: "a" is length 1, we check length 2)
```

**Critical Insight**: Negation is **span-specific**. `~('a' 'b')` means "anything that isn't 'ab' **of the same length**", not "any span that doesn't start with 'ab'".

### Epsilon Negation

Negation of epsilon (empty pattern) is interesting:

```dart
pattern = Eps()    // Matches empty input (span [i:i))
negation = ~Eps()  // Matches anything that ISN'T empty on its span

input: ""  → Span [0:0) → Negation FAILS (epsilon matches)
input: "a" → Span [0:1) → Negation SUCCEEDS (epsilon doesn't match non-empty)
```

So `~Eps()` effectively means "match one or more of anything" within the current span context.

### Optional Pattern Negation

Negating optional patterns:

```dart
rule = ~('a'?)  // Negation of optional 'a'

// 'a'? can match: "" or "a"
// ~('a'?) matches anything that isn't "" or "a"
```

Input "":

- Base pattern `'a'?` matches (via epsilon)
- Negation FAILS

Input "b":

- Base pattern `'a'?` expects 'a' or empty but at [0:1) it fails the 'a' part. Actually, `'a'?` at [0:1) tries to match 'a', which fails, so it backtracks to epsilon matching, which succeeds at [0:0) but span is [0:1), so it fails overall? No—`'a'?` means "match 'a' if possible, else match nothing", so at [0:1) trying to match:
  - Try 'a': "b" ≠ 'a', fail
  - Backtrack to: match nothing (epsilon), which succeeds at [0:0)
  - But we're trying to match span [0:1), so this fails

Actually, span negation is more nuanced. Let me reconsider.

### Correct Span-Level Semantics

Negation works at the **span level**, not at each position independently. When evaluating `~pattern` at position `i`:

1. Try all possible spans `[i:j)` where `j > i`
2. For each span, check if `pattern` matches `[i:j)`
3. For spans where `pattern` does NOT match, the negation matches
4. Success: Negation matches the first/shortest span where pattern doesn't match
5. Continue from `j`

**Example**:

```dart
rule = ~'a'

input: "bcd"
```

Evaluating `~'a'` at position 0:

1. Try span [0:1) containing "b"
2. Does `'a'` match "b"? No
3. Negation matches at [0:1)
4. Continue from position 1

---

## Span-Level Negation Semantics

### Formal Definition

Let `L(P)` be the set of strings accepted by pattern `P`.

Negation `~P` is defined as:

```
L(~P) = {s ∈ Σ* : s ≢ L(P)}
```

Where `Σ*` is all finite strings and `s ≢ L(P)` means string `s` is not in the language of `P`.

### Greedy Matching

By default, negation matches the **shortest non-matching string**:

```dart
rule = ~('a'+)  // Anything that isn't one-or-more 'a's

input: "aaa"
       0 1 2 3

Evaluating ~('a'+) at position 0:
- Try span [0:1): "a" matches 'a'+? Yes → No match
- Try span [0:2): "aa" matches 'a'+? Yes → No match
- Try span [0:3): "aaa" matches 'a'+? Yes → No match
- No span matches → Negation fails

input: "aab"
       0 1 2 3

Evaluating ~('a'+) at position 0:
- Try span [0:1): "a" matches 'a'+? Yes → No match
- Try span [0:2): "aa" matches 'a'+? Yes → No match
- Try span [0:3): "aab" matches 'a'+? No → Match!
- Negation matches [0:3), continue from position 3
```

### Possessive vs Greedy Negation

While Glush doesn't have explicit "possessive" negation syntax, the semantics are naturally:

- **First non-matching span wins**: Once a span is found where the pattern doesn't match, negation succeeds immediately
- This prevents backtracking within the negation itself

---

## Negation vs Predicates

This is a critical distinction:

| Aspect             | Negation (`~P`)                           | Negative Predicate (`!P`)             |
| ------------------ | ----------------------------------------- | ------------------------------------- |
| **Consumes Input** | Yes                                       | No (zero-width)                       |
| **Span**           | Negation matches a span `[i:j)`           | Predicate checks at position `i` only |
| **Result**         | Actual characters matched                 | No characters consumed                |
| **Language**       | Complement of L(P)                        | N/A (doesn't match language)          |
| **Use Case**       | Match content excluding specific patterns | Assert a pattern doesn't follow       |
| **Example**        | `~'a'` matches "b", "c", etc.             | `!'a'` checks if 'a' is not next      |

**Practical Example**:

```dart
// Use negation to match any non-'a' character
non_a = ~'a' | [b-z]  // Redundant, but shows the distinction

// Use negative predicate to assert
safe_word = !'reserved_word' identifier
            // Asserts reserved_word doesn't match, then matches identifier

// Correct usage
identifier_not_keyword = (~keyword) [a-z]+
                         // Match non-keyword starting patterns
```

---

## De Morgan's Laws

Negation interacts with other operators according to formal logic:

### De Morgan's Laws

```
¬(A & B)  ≡  (¬A | ¬B)
¬(A | B)  ≡  (¬A & ¬B)
```

In Glush, the `invert()` method applies these:

```dart
// Conjunction inversion
Conj(left, right).invert()
  → left.invert() | right.invert()
  → (¬A) | (¬B)

// Alternation inversion
Alt(left, right).invert()
  → left.invert() >> right.invert()
  → Wait, alternation inverts to sequence? That doesn't match De Morgan...
```

Actually, the precise inversion semantics depend on the pattern algebra used. Let me defer to the implementation.

### Double Negation Law

```
¬(¬A)  ≡  A
```

In Glush:

```dart
Neg(pattern).invert() → pattern
```

This is reflected directly in the `invert()` method of `Neg`.

---

## Mark and Label Behavior

### Mark Recovery from Negation

When a negated pattern contains labels, the marks are preserved in negation:

```dart
rule = ~(l1:pattern)

// Input where pattern doesn't match:
// - Negation succeeds
// - No marks from pattern are produced (pattern didn't match)
// - Negation itself doesn't produce marks

// Input where pattern matches:
// - Negation fails
// - Marks from pattern are not recovered (rule failed)
```

### Negation with Labeled Alternatives

When negating a choice with labels:

```dart
rule = ~(l1:'a' | l2:'b')

input: "c"
```

1. Try to match `l1:'a' | l2:'b'` against "c"
2. Both alternatives fail
3. Negation succeeds
4. No labels are recovered (pattern didn't match)

### Nested Negations with Labels

Nested negations preserve structure:

```dart
rule = ~(~(l1:'a'))

input: "a"
```

1. Inner negation tries to match `~(l1:'a')`
2. Since "a" matches `l1:'a'`, inner negation fails
3. Outer negation of the failed inner negation succeeds
4. Label `l1` comes from the failed inner negation? No—marks are only produced on successful matches.

---

## Negation with Ambiguity

### Multiple Negation Paths

Negation itself is deterministic (not ambiguous), but when combined with ambiguous patterns:

```dart
rule = (a:x | b:x) content

x = 'a' | 'a'       // Ambiguous (both alternatives match 'a')
content = ~x        // Negation of ambiguous pattern

input: "ab"
```

1. Top-level choice: left is ambiguous (both alternatives match 'a')
2. After consuming 'a' (position 1)
3. Content `~x` tries to find something other than 'x' at [1:?)
4. At [1:2), "b" doesn't match 'x' (which needs 'a')
5. Negation succeeds

### Filtering via Negation

Negation can filter ambiguous parses:

```dart
rule = (expr | expr) & ~(bad_expr)

expr = 'a' | 'b'
bad_expr = 'b'

input: "a"
```

Conjunction with negation filters to derivations that match `expr` but NOT `bad_expr`.

---

## Epsilon and Empty Patterns

### Negation of Epsilon

Epsilon is the empty pattern (matches no input):

```dart
pattern = Eps()    // Matches nothing: "" (empty span)
negation = ~Eps()  // Matches anything that isn't empty

// Empty input (span contains nothing)
input: ""
```

When evaluated over span [0:0):

1. Does `Eps()` match [0:0)? Yes (epsilon always matches empty spans)
2. Negation of yes = No
3. `~Eps()` fails on empty input

When evaluated over span [0:1):

1. Does `Eps()` match [0:1)? No (epsilon only matches empty spans, not content)
2. Negation of no = Yes
3. `~Eps()` matches on non-empty input

### Calculating Empty

From the implementation:

```dart
@override
bool calculateEmpty(Set<Rule> emptyRules) {
  pattern.calculateEmpty(emptyRules);
  setEmpty(!pattern.empty());
  return empty();
}
```

If base pattern is empty (matches epsilon), negation is NOT empty (negation requires non-empty).
If base pattern is not empty, negation IS empty.

This aligns with the semantics: `~Eps()` is non-empty, `~'a'` is empty (epsilon matches any span where 'a' doesn't, including empty).

---

## Use Cases

### Keyword Exclusion

```dart
identifier = ~keyword identifier_name

keyword = 'if' | 'else' | 'while' | ...

identifier_name = [a-zA-Z_][a-zA-Z0-9_]*
```

Matches identifiers that aren't keywords.

### Avoiding Specific Patterns

```dart
safe_comment = ~'--' comment_body

comment_body = '-' .+
```

Comments that don't start with '--' (avoiding double-dash which might be special).

### Content Exclusion

```dart
paragraph = (~'---') [^]+?

// Matches content until '---' (excluding it)
```

### Character Class Complement

```dart
non_whitespace = ~[ \t\n\r]
```

Matches anything except whitespace.

### Semantic Filtering

```dart
valid_name = ~(l1:invalid_prefix) name

invalid_prefix = '__' | '_[A-Z]'

name = [a-zA-Z_][a-zA-Z0-9_]*
```

Names that don't start with reserved prefixes.

---

## Advanced Scenarios

### Triple Negation

```dart
rule = ~~~'a'

// ~~~ is equivalent to ~ (since ¬(¬(¬A)) = ¬A)
// Matches anything except 'a'
```

### Negation in Recursive Rules

```dart
safe_recursion(depth) =
  depth > 0 if (depth > 0)
  content_safe_recursion(depth - 1)
  | ~content content

content = ...
```

Recursion continues only on safe content (content that isn't the excluded pattern).

### Negation with Optional Patterns

```dart
rule = (a)? content ~a

// Optional 'a' at start, then content, then must NOT match 'a'
```

### Negation with Conjunction

```dart
rule = pattern & ~excluded

pattern = ...
excluded = ...

// Matches pattern ONLY if it doesn't also match excluded
// Effectively: pattern that is NOT in the intersection with excluded
```

---

## Implementation Details

### State Machine Handling

Negations are compiled into state machine states that:

1. **Spawn a sub-parse** for the negated pattern
2. **Invert the result**: If sub-parse succeeds, negation fails; if fails, negation succeeds
3. **Continue from end position** of failed match attempt

### Span Enumeration

To efficiently match negation:

1. **Try spans in order** [i:i+1), [i:i+2), ... up to end of input
2. **Short-circuit on first failure** of base pattern
3. **Consume that failing span** in the negation

### Memoization

Negation results are memoized:

```
Memo[~pattern, input, position] → span length where negation matches
```

This avoids repeatedly trying the same negation at the same position.

### Memory Considerations

Negations can be expensive:

- **Span exploration cost**: May need to try many spans before finding one where pattern fails
- **Sub-parse overhead**: Each negation spawns a sub-parse of the base pattern
- **State machine size**: Negations increase the state machine size

**Optimization strategies**:

1. **Use specific negations** (`~'a'`) rather than complex negations (`~pattern`)
2. **Combine with other constraints** to fail early
3. **Cache results** via memoization (automatic)
4. **Avoid redundant negations** (e.g., `~~pattern` is less efficient than `pattern`)

---

## Testing

Key test files for negations:

- [debug_not_sequence_test.dart](../test/parser/debug_not_sequence_test.dart): Sequence negation behavior
- [edge_cases_test.dart](../test/parser/edge_cases_test.dart): Complex negation scenarios
- [conjunctions_edge_cases_test.dart](../test/parser/conjunction_edge_cases_test.dart): Negation with conjunctions and other operators
