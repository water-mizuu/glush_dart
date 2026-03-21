# Glush — Versatile Parser Toolkit for Dart

A powerful, flexible parsing library for Dart that supports **CFG Parsing**, **state machines**, **parse forests**, and **parser code generation**. Build anything from simple tokenizers to complex expression parsers with minimal boilerplate.

> Note: This library and its tooling were developed with the help of AI-assisted generation.

**Key Features:**
- **Pattern-based DSL** — Define grammars using Dart-native operators (`>>`, `|`, `*`, `+`, `?`)
- **Multiple parsing methods** — Recognition, parse tree enumeration, full parse forests (SPPF), streaming parse forests
- **Mark collection & Evaluation** — Track positions and capture spans; evaluate results elegantly with the `Evaluator` class
- **Semantic actions** — Attach callbacks to patterns to evaluate or transform results during parsing
- **Parse forest support** — Handle ambiguous grammars efficiently with SPPF (Shared Packed Parse Forest)
- **Forest analysis** — Count derivations, detect cycles, and analyze grammar with SCC-based metrics
- **Streaming support** — Parse large files or network streams with bounded memory using `parseWithForestAsync()`
- **Lookahead predicates** — Use AND (`&`) and NOT (`!`) for contextual matching without consuming input
- **No external dependencies** — Pure Dart implementation

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Patterns and Operations](#patterns-and-operations)
4. [Parsing Methods](#parsing-methods)
5. [Parse Forest Analysis](#parse-forest-analysis)
6. [Mark Collection](#mark-collection)
7. [Semantic Actions](#semantic-actions)
8. [Operator Precedence](#operator-precedence)
9. [Lookahead Predicates](#lookahead-predicates)
10. [Code Generation](#code-generation)
11. [Examples](#examples)
12. [Best Practices](#best-practices)
13. [API Reference](#api-reference)

---

## Quick Start

### Basic Expression Grammar with Actions

```dart
import 'package:glush/glush.dart';

void main() {
  // Define a simple arithmetic grammar with semantic actions
  final grammar = Grammar(() {
    late Rule expr, term, factor, number;

    // number = [0-9]+ ⇒ parse to int
    number = Rule('number', () =>
      Token.charRange('0', '9').plus()
        .withAction<int>((span, _) => int.parse(span))
    );

    // factor = number | '(' expr ')'
    factor = Rule('factor', () =>
      number() |
      (Token.char('(') >>
       expr() >>
       Token.char(')'))
        .withAction<int>((_, children) => children[1])
    );

    // term = factor (('*' | '/') factor)*
    term = Rule('term', () =>
      factor() |
      (Marker('mul') >> term() >> Token.char('*') >> factor())
        .withAction<int>((_, children) => children[1] * children[3]) |
      (Marker('div') >> term() >> Token.char('/') >> factor())
        .withAction<int>((_, children) => children[1] ~/ children[3])
    );

    // expr = term (('+' | '-') term)*
    expr = Rule('expr', () =>
      term() |
      (Marker('add') >> expr() >> Token.char('+') >> term())
        .withAction<int>((_, children) => children[1] + children[3]) |
      (Marker('sub') >> expr() >> Token.char('-') >> term())
        .withAction<int>((_, children) => children[1] - children[3])
    );

    return expr();
  });

  final parser = SMParser(grammar);

  // Recognize
  print(parser.recognize('2+3*4'));  // true

  // Parse all trees and evaluate them
  final results = parser.enumerateAllParsesWithResults<int>('2+3*4').toList();
  for (final result in results) {
    print('Value: ${result.value}');  // 14 (left-assoc) or 14 (right-assoc)
  }

  // Parse with forest and marks
  final forest = parser.parseWithForest('2+3*4');
  if (forest is ParseForestSuccess) {
    print('Forest nodes: ${forest.forest.countNodes()}');
    print('Forest families: ${forest.forest.countFamilies()}');
  }
}
```

---

## Core Concepts

### 1. Grammars and Rules

A **Grammar** is a collection of rules. Each rule defines how to match part of the input:

```dart
final grammar = Grammar(() {
  late Rule expr, term;

  expr = Rule('expr', () =>
    term() >> (Token.char('+') >> term()).star()
  );

  term = Rule('term', () =>
    Token.charRange('0', '9').plus()
  );

  return expr();  // Return the start rule
});
```

**Key points:**
- Use `late` for mutually recursive rules
- Patterns are built with fluent operators: `>>`, `|`, `*`, `+`, `?`
- Return the **start rule** from the grammar function
- Rule names are arbitrary identifiers

### 2. Tokens and Characters

Tokens match single characters by code unit:

```dart
Token.char('a')                     // Match 'a'
Token.charRange('0', '9')           // Match '0'-'9'
Token.charRange('a', 'z')          // Match 'a'-'z'
Token.charRange('0', '9').plus()   // One or more digits
Token.charRange('a', 'z').plus()   // One or more lowercase letters
```

### 3. Patterns

Patterns combine tokens and rules to form larger expressions:

| Pattern | Syntax | Meaning |
|---------|--------|---------|
| Sequence | `A >> B` | Match A then B |
| Choice | `A \| B` | Match A or B |
| Optional | `A.maybe()` | Match A or nothing |
| Repeat (0+) | `A.star()` | Match A zero or more times |
| Repeat (1+) | `A.plus()` | Match A one or more times |
| Empty | `Eps()` | Match nothing (zero-length) |
| Call | `rule()` | Reference another rule |
| Predicate (AND) | `A.and() >> B` | Look ahead for A without consuming |
| Predicate (NOT) | `A.not() >> B` | Lo ahead, fail if A matches |

### 4. Character Classes

Common ASCII ranges:

```dart
Token.charRange('0', '9')   // Digits 0-9
Token.charRange('a', 'z')  // Lowercase a-z
Token.charRange('A', 'Z')  // Uppercase A-Z
Token.char(' ').maybe()     // Space (optional)
```

---

## Patterns and Operations

### Sequence (`>>`) — Consecutive Patterns

Match patterns in order:

```dart
Token.char('h') >> Token.char('i')  // Matches "hi"

// In rules:
Rule('greeting', () =>
  Pattern.string('hello') >> Token(ExactToken(32)) >> Pattern.string('world')
)
```

**Tree structure:** One child per element in sequence, in order.

---

### Alternation (`|`) — Choice

Match any one of the alternatives:

```dart
Token.char('0') | Token.char('1') | Token.char('2')  // Match a digit 0-2

// In rules:
Rule('keyword', () =>
  Pattern.string('if') | Pattern.string('else') | Pattern.string('while')
)
```

**Tree structure:** Exactly ONE child (the matched alternative).

---

### Repetition — Star (`*`) and Plus (`+`)

**Star (`A.star()`)** — Zero or more matches:

```dart
Token.char('a').star()  // Matches "", "a", "aa", "aaa", ...

// Expands internally to handle efficient recursion
```

**Plus (`A.plus()`)** — One or more matches:

```dart
Token.char('a').plus()  // Matches "a", "aa", "aaa", ... (not "")
```

**Tree structure:**
Both operators natively return a flat `List` of their child elements during semantic action evaluation or SPPF forest extraction, making AST generation trivial rather than dealing with nested sequential structures.

---

### Optional (`A.maybe()`)

Match A or nothing:

```dart
Token.char('a').maybe()  // Matches "a" or ""

// Equivalent to: (A | Eps())
```

---

### Rule References (`Call`)

Reference another rule from within a pattern:

```dart
final grammar = Grammar(() {
  late Rule digit, number;

  digit = Rule('digit', () => Token.charRange('0', '9'));

  number = Rule('number', () =>
    digit() >> digit().star()
  );

  return number;
});
```

**Tree structure:** Expands the referenced rule inline.

---

### Epsilon (`Eps`) — Empty Match

Match zero characters (always succeeds):

```dart
Eps()  // Matches nothing

// Useful in:
Rule('optional', () => Token('a') | Eps())
```

---

## Parsing Methods

### Method 1: `recognize()` — Fast Yes/No

Check if input is valid without building trees:

```dart
if (parser.recognize('12+34')) {
  print('Valid');
}
```

**Returns:** `bool`
**Time:** O(n) where n = input length
**Space:** O(n)
**Use when:** Just need validation

---

### Method 2: `enumerateAllParses()` — Lazy Tree Enumeration

Iterate through all possible parse trees:

```dart
final trees = parser.enumerateAllParses('12+34').toList();

for (final tree in trees) {
  print(tree.symbol);           // Rule name
  print(tree.toTreeString());   // Visual tree

  // Access span
  print(tree.start);            // Start position
  print(tree.end);              // End position
  print(tree.getMatchedText(input));  // Matched text
}
```

**Returns:** `Iterable<ParseDerivation>`
**Time to 1st tree:** O(depth)
**Time for D trees:** O(n² + D×depth)
**Space:** O(n²) memoization
**Laziness:** ✅ Builds trees on-demand
**Use when:**
- Need all possible parses
- Memory is tight
- Often only need first few results

---

### Method 3: `enumerateAllParsesWithResults<T>()` — Lazy with Semantic Actions

Enumerate trees and evaluate semantic actions:

```dart
final results = parser.enumerateAllParsesWithResults<int>('2+3*4').toList();

for (final result in results) {
  print(result.value);      // Evaluated semantic value
  print(result.tree);       // The parse tree
}
```

**Returns:** `Iterable<ParseDerivationWithValue<T>>`
**Semantics:** Bottom-up evaluation of `.withAction()` callbacks
**Use when:** Combining parsing and semantic evaluation

---

### Method 4: `parseWithForest()` — Parse Forest (SPPF)

Build a shared packed parse forest for all ambiguous parses:

```dart
final outcome = parser.parseWithForest('12+34');

if (outcome is ParseForestSuccess) {
  final forest = outcome.forest;

  // Forest statistics
  print('Nodes: ${forest.countNodes()}');
  print('Families: ${forest.countFamilies()}');

  // Extract all trees
  final trees = forest.extract().toList();
  for (final tree in trees) {
    print(tree.toTreeString());
  }

  // Extract with semantic results (March 2026)
  final results = parser.enumerateForestWithResults<int>(outcome, '12+34');
  for (final result in results) {
    print('Value: ${result.value}');
  }
} else if (outcome is ParseError) {
  print('Parse error at position ${outcome.position}');
}
```

**Returns:** `ParseOutcome<T>` = `ParseForestSuccess<T> | ParseError<T>`
**Time to build:** O(n³) (CYK-like)
**Time to extract:** O(D) where D = derivations
**Space:** O(F) forest nodes
**Laziness:** ❌ Builds entire forest upfront
**Use when:**
- Highly ambiguous grammars
- Need all possible parses
- Forest structure saves memory vs reconstruction
- Can afford upfront O(n³) cost
- **Cyclic Grammars:** Robustly handles cyclic ε-grammars with built-in cycle detection to prevent infinite recursion and stack overflows.

---

### Method 5: `parseAmbiguous()` — Ambiguity with GSS

Parse ambiguous grammars efficiently without building a full SPPF, returning multiple valid sequences of marks:

```dart
final outcome = parser.parseAmbiguous('12+34');
if (outcome is ParseAmbiguousForestSuccess) {
  // Use outcome...
}
```

**Key Features:**
- Powered by a **Graph-Structured Stack (GSS)** and a branching list (`GlushList`) to handle multiple parse paths without exponential memory growth.
- Built on the marks system — returns multiple sequences of marks representing different successful parses, which can be evaluated elegantly with the `Evaluator` class. (Note: standard `parse()` also relies on the marks system).

**Returns:** `ParseAmbiguousForestSuccess | ParseFailure` containing mark lists
**Use when:** You need to evaluate multiple valid parses of a string efficiently using a mark evaluator.

---

### Method 6: `parseWithForestAsync()` — Streaming Parse Forest

Build a parse forest from streaming input without loading the entire input into memory:

```dart
// Stream input from network, file, or any async source
Stream<String> inputStream = ...;

final outcome = await parser.parseWithForestAsync(inputStream);

if (outcome is ParseForestSuccess) {
  final forest = outcome.forest;

  // Forest statistics
  print('Nodes: ${forest.countNodes()}');
  print('Families: ${forest.countFamilies()}');

  // Extract all trees
  final trees = forest.extract().toList();
  for (final tree in trees) {
    print(tree.toTreeString());
  }

  // Extract with semantic results
  final results = parser.enumerateForestWithResults<int>(outcome, inputStream);
  for (final result in results) {
    print('Value: ${result.value}');
  }
} else if (outcome is ParseError) {
  print('Parse error at position ${outcome.position}');
}
```

**Parameters:**
- `input: Stream<String>` — Async stream of input chunks
- `lookaheadWindowSize: int` — Maximum lookahead buffer size (default: 1MB) to prevent unbounded memory growth

**Returns:** `Future<ParseOutcome>` = `Future<ParseForestSuccess | ParseError>`
**Time to build:** O(n³) (CYK-like)
**Space:** O(F) forest nodes + O(w) lookahead window (bounded)
**Streaming:** ✅ Processes input incrementally
**Use when:**
- Parsing large files or network streams
- Input size exceeds available memory
- Real-time parsing with buffered lookahead
- Need parse forest from streaming data

---

## Parsing Methods Comparison

| Method | Returns | Time Profile | Space Profile | Streaming | Best for |
|--------|---------|--------------|---------------|-----------|----------|
| `recognize()` | `bool` | O(n) | O(n) | ❌ | Fast validation |
| `parse()` | `ParseSuccess` (Marks)| O(n) | O(n) | ❌ | Unambiguous parsing evaluated via `Evaluator` |
| `parseAmbiguous()` | `ParseAmbiguousForestSuccess`| Fast: O(depth) to first | O(n) GSS | ❌ | Ambiguous parsing evaluated via `Evaluator` |
| `enumerateAllParses()` | `Iterable<ParseDerivation>`| Fast: O(depth) to first | O(n²) | ❌ | Small input, few AST trees |
| `enumerateAllParsesWithResults()`| `Iterable<Value>`| Fast: O(depth) to first | O(n²) | ❌ | Direct evaluation, few outcomes |
| `parseWithForest()` | `ParseForestSuccess` | Slow: O(n³) upfront | O(F) set nodes | ❌ | Highly ambiguous, all trees via SPPF |
| `parseWithForestAsync()` | `Future<ParseForestSuccess>` | Slow: O(n³) upfront | O(F) + O(w) bounded | ✅ | Streaming input, bounded memory |

---

## Parse Forest Analysis

After building a parse forest, you can analyze its structure and count derivations using strongly connected component (SCC) analysis.

### Forest Statistics

```dart
final outcome = parser.parseWithForest('a+a');
if (outcome is ParseForestSuccess) {
  final forest = outcome.forest;

  // Basic metrics
  print('Total nodes: ${forest.countNodes()}');
  print('Total families (alternatives): ${forest.countFamilies()}');
}
```

### Derivation Counting with SCC Analysis

Count the total number of distinct parse derivations using Tarjan's strongly connected component algorithm:

```dart
final outcome = parser.parseWithForest('2+3*4');
if (outcome is ParseForestSuccess) {
  final forest = outcome.forest;
  final counts = forest.countDerivationsWithSCC();

  print('Total derivations: ${counts['count']}');           // BigInt (unbounded)
  print('Has cycles (left recursion): ${counts['hasCycles']}'); // bool
  print('Number of SCCs: ${counts['sccs']}');               // int
  print('Forest size: ${counts['forestSize']}');            // int
}
```

**Why SCC Analysis?**
- **Cycle Detection:** Identifies left-recursive or cyclic grammars that produce infinite derivations
- **Precise Counting:** Uses dynamic programming with memoization to count exact derivations even in recursive grammars
- **BigInt Support:** Handles grammars with very large (or infinite) numbers of derivations

**Key Points:**
- `count`: Total number of distinct parse trees (as `BigInt` for unbounded counts)
- `hasCycles`: `true` if the grammar has left-recursion or cycles
- `sccs`: Number of strongly connected components in the parse forest
- `forestSize`: Total number of nodes in the forest

### When to Use SCC Analysis

- Detect **left-recursive grammars** (common in expression parsing)
- **Validate ambiguity** — Understand how many ways input can be parsed
- **Grammar debugging** — Check if precedence rules are working as expected
- **Performance analysis** — Identify grammars with exponential derivation counts

---

## Mark Collection
```dart
final grammar = Grammar(() {
  late Rule expr;

  expr = Rule('expr', () =>
    // Mark the start of an operator
    Marker('start_op') >>
    Token.char('+') >>
    // Mark the end
    Marker('end_op') >>
    Token.char('5')
  );

  return expr();
});

// After parsing, marks are available in the parse state
// Useful for error reporting, highlighting, semantic actions
```

**Usage:**
```dart
// During parse tree evaluation, access marked positions
final parser = SMParser(grammar);
final result = parser.parse('+5');

// You can use marks in evaluators to track spans:
// e.g., "operator 'add' spans from position 0 to 1"
```

### String Marks

Capture string values at parse positions:

```dart
final grammar = Grammar(() {
  final keyword = Pattern.string('if').withAction<String>((span, _) {
    return span;  // Return matched text
  });

  return Rule('kw', () => keyword)();
});
```

### Evaluator — Elegant Mark-based Evaluation

The `Evaluator` class provides a concise, recursive DSL for evaluating the list of marks returned by `parse()`. It's often the simplest way to build an interpreter for your grammar.

```dart
final evaluator = Evaluator<num>(($) {
  return {
    'add': () => $<num>() + $<num>(),
    'sub': () => $<num>() - $<num>(),
    'mul': () => $<num>() * $<num>(),
    'div': () => $<num>() / $<num>(),
    'group': () => $<num>(),
    'number': () => num.parse($<String>()),
  };
});

final result = parser.parse('1+2*(3+4)');
if (result is ParseSuccess) {
  // evaluate() returns (result, remaining_marks)
  final (value, _) = evaluator.evaluate(result.result.marks);
  print('Result: $value'); // 15
}
```

**How it works:**
- The factory function receives a `consume` helper (aliased to `$` here).
- Calling `$<T>()` recursively evaluates the next mark in the list.
- If the next mark is a handler key, that handler is executed and its result returned.
- If the next mark is a raw value (like from a regex or string), it's returned directly as `T`.

---

## Semantic Actions

**Semantic actions** calculate values during parsing using `.withAction<T>()`. Attach a callback to any pattern — it executes during `enumerateAllParsesWithResults<T>()` with bottom-up evaluation.

### Basic Actions

```dart
Token.charRange('0', '9').plus()
  .withAction<int>((span, _) => int.parse(span))
```

Parameters:
- `span: String` — The matched text from input
- `childResults: List<dynamic>` — Results from child semantic actions
- Returns `T` — Your computed value

### Example: Arithmetic Evaluator

```dart
final grammar = Grammar(() {
  late Rule expr, term, number;

  number = Rule('number', () =>
    Token.charRange('0', '9').plus()
      .withAction<int>((span, _) => int.parse(span))
  );

  term = Rule('term', () =>
    number() |
    (term() >> Token.char('*') >> number())
      .withAction<int>((_, c) => c[0] * c[2])
  );

  expr = Rule('expr', () =>
    term() |
    (expr() >> Token.char('+') >> term())
      .withAction<int>((_, c) => c[0] + c[2])
  );

  return expr();
});

final parser = SMParser(grammar);
final results = parser.enumerateAllParsesWithResults<int>('2+3*4').toList();
print(results[0].value);  // 14
```

### Bottom-Up Evaluation

Actions execute **bottom-up** — child results are computed first:

```
Expression: 2 + 3 * 4

1. Evaluate "2" → 2
2. Evaluate "3" → 3
3. Evaluate "4" → 4
4. Evaluate "3 * 4" → 12 (uses results from steps 2-3)
5. Evaluate "2 + 12" → 14 (uses results from steps 1-4)
```

**Child results structure:**
- For sequence `A >> B >> C`: `[resultA, resultB, resultC]`
- For alternation `A | B`: `[resultOfSelected]` (single element)
- For star `A*`: `[resultA, flatListOfRest]` or `[]` if zero

### Example: Building an AST

```dart
abstract class Expr {}

class NumExpr extends Expr {
  final int value;
  NumExpr(this.value);
}

class BinOpExpr extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  BinOpExpr(this.op, this.left, this.right);
}

final grammar = Grammar(() {
  late Rule expr, term, number;

  number = Rule('number', () =>
    Token.charRange('0', '9').plus()
      .withAction<NumExpr>((span, _) => NumExpr(int.parse(span)))
  );

  term = Rule('term', () =>
    number() |
    (term() >> Token.char('*') >> number())
      .withAction<BinOpExpr>((_, c) => BinOpExpr('*', c[0], c[2]))
  );

  expr = Rule('expr', () =>
    term() |
    (expr() >> Token.char('+') >> term())
      .withAction<BinOpExpr>((_, c) => BinOpExpr('+', c[0], c[2]))
  );

  return expr();
});
```

### Forest-based Evaluation (March 2026)

Evaluate semantic actions on parse forests:

```dart
final outcome = parser.parseWithForest('2+3*4');
if (outcome is ParseForestSuccess) {
  final results = parser.enumerateForestWithResults<int>(outcome, '2+3*4');
  for (final result in results) {
    print(result.value);  // Evaluated semantic value
  }
}
```

---

## Operator Precedence

### Approach 1: Natural Precedence (Recommended)

Use recursive descent with separate rules per precedence level. Left/right recursion determines associativity:

```dart
final grammar = Grammar(() {
  late Rule expr, term, factor, number;

  number = Rule('number', () =>
    Token.charRange('0', '9').plus()
      .withAction<int>((span, _) => int.parse(span))
  );

  // Highest precedence: parentheses and numbers
  factor = Rule('factor', () =>
    number() |
    (Token.char('(') >> expr() >> Token.char(')'))
  );

  // Medium precedence: * and /
  term = Rule('term', () =>
    factor()
      .withAction<int>((_, c) => c[0]) |
    (term() >> Token.char('*') >> factor())
      .withAction<int>((_, c) => c[0] * c[2]) |
    (term() >> Token.char('/') >> factor())
      .withAction<int>((_, c) => c[0] ~/ c[2])
  );

  // Lowest precedence: + and -
  // Left-recursive for left-associativity: expr → expr '+' term
  expr = Rule('expr', () =>
    term()
      .withAction<int>((_, c) => c[0]) |
    (expr() >> Token.char('+') >> term())
      .withAction<int>((_, c) => c[0] + c[2]) |
    (expr() >> Token.char('-') >> term())
      .withAction<int>((_, c) => c[0] - c[2])
  );

  return expr();
});

// Usage:
final parser = SMParser(grammar);
final results = parser.enumerateAllParsesWithResults<int>('2+3*4').toList();
print(results[0].value);  // 14 (correct precedence)
```

**Advantages:**
- ✅ Clear, idiomatic grammar structure
- ✅ Works across all parsing methods (recognition, enumeration, forest)
- ✅ Efficient and straightforward
- ✅ Easy to understand and modify
- ✅ Natural left/right associativity via recursion direction

**Left vs Right Associativity:**

```dart
// LEFT-ASSOCIATIVE (standard):
// 10 - 5 - 2 = (10 - 5) - 2 = 3
expr = Rule('expr', () =>
  expr() >> Token.char('-') >> term()  // Left recursion
);

// RIGHT-ASSOCIATIVE:
// a ^ b ^ c = a ^ (b ^ c)
expr = Rule('expr', () =>
  term() >> Token.char('^') >> expr()  // Right recursion
);
```

### Approach 2: Explicit Precedence Levels (Alternative)

For grammar files and code generation, use precedence-labeled alternatives:

```dart
// In .glush grammar format:
expr =
  1| pair expr "=>" expr
  2| add expr "+" expr
  3| mul expr "*" expr
  11| number
  ;
```

**In Dart API:**

```dart
expr = Rule('expr', () {
  return (Marker('pair') >> expr() >> Token.char('=') >> Token.char('>') >> expr())
    .atLevel(1) |
    (Marker('add') >> expr() >> Token.char('+') >> expr())
      .atLevel(2) |
    (Marker('mul') >> expr() >> Token.char('*') >> expr())
      .atLevel(3) |
    Token.charRange('0', '9').plus()
      .atLevel(11);
});

// With precedence constraints (filter which alternatives can be called):
expr = Rule('expr', () {
  return expr(minPrecedenceLevel: 2) >> Token.char('+') >> expr(minPrecedenceLevel: 3) |
         expr(minPrecedenceLevel: 3) >> Token.char('*') >> expr();
});
```

---

## Lookahead Predicates

Test conditions without consuming input. Predicates are fully integrated into the state machine resolution without fallback overhead, allowing for highly efficient parsing of complex lookahead grammars. Use AND (`&`) and NOT (`!`) predicates:

### AND Predicate (`A.and()`)

Succeed **only if** A matches at current position, but don't consume:

```dart
final grammar = Grammar(() {
  // Match "a" only if followed by "b"
  final pattern = Token.char('a').and() >> Token.char('a') >> Token.char('b');

  return Rule('test', () => pattern);
});

final parser = SMParser(grammar);
parser.recognize('ab');   // true (both match)
parser.recognize('ac');   // false (AND fails on "a")
```

### NOT Predicate (`A.not()`)

Succeed **only if** A doesn't match, without consuming:

```dart
final grammar = Grammar(() {
  // Match any character except 'x'
  final notX = Token.char('x').not() >>
    Token.charRange('a', 'z');  // a-z

  return Rule('test', () => notX);
});

final parser = SMParser(grammar);
parser.recognize('a');    // true
parser.recognize('x');    // false (NOT fails)
```

### Common Use Cases

**Keyword matching** (don't match if followed by word char):

```dart
Token.string('if').not() >> Token.string('iff')  // Won't match "if" in "iff"
```

**Avoiding ambiguity** in tokenization:

```dart
final identifier = Token.charRange('a', 'z').plus() >>
  Token.char('_').not() >> // Not followed by underscore
  Token.charRange('0', '9').star();  // Then digits optional
```

### How Lookahead Predicates Work (Implementation Details)

Glush implements lookahead predicates (&pattern and !pattern) with **zero runtime overhead** by fully integrating them into the state machine resolution process, rather than using backtracking or fallback mechanisms.

**The Mechanism:**

1. **Separate Sub-Parse**: When the parser encounters a predicate, it spawns a lightweight **sub-parse** (tracked by `PredicateTracker`) that runs on the same state machine alongside the main parse. The sub-parse is pinned to a fixed input position—it never consumes input.

2. **Concurrent Resolution with Work Queue**: The sub-parse and main parse run concurrently within the same work queue, sharing:
   - The same set of parser states and transitions
   - The same memoization tables (no redundant work)
   - The state machine's efficient frame-based resolution

3. **Frame Catch-Up from Earlier Positions**: When a predicate sub-parse spawns at position M while the main parser is at position N (where N > M), the frames from the predicate sub-parse need to "catch up" to the current position:
   - The work queue is a priority queue ordered by input position (earliest first)
   - A predicate frame at position M is processed through M → M+1 → M+2 → ... → N
   - At each position, the frame transitions are resolved and result frames advance to the next position
   - Token history is maintained so frames can access already-parsed characters from earlier positions
   - Once the sub-parse frame catches up to the current position, it determines success/failure

4. **Outcome Determination**:
   - **AND Predicate (`&A`)**: Succeeds if the sub-parse for `A` finds at least one match. The main parse is allowed to proceed past the predicate.
   - **NOT Predicate (`!A`)**: Succeeds if the sub-parse for `A` is exhausted without finding any match. This is checked when the sub-parse's active frame count reaches zero.
   - **Predicate Completion**: When a predicate matches or exhausts, the `PredicateTracker` is marked as completed, and waiting parent frames are resumed at their correct position.

5. **No Backtracking**: Because predicates run in parallel with the main parse (not sequentially before/after), there's no need for expensive backtracking. The state machine's built-in support for non-determinism handles multiple paths naturally.

**Why This is Efficient:**

- **Shared Infrastructure**: Lookahead uses the same grammar, state machine, and frame machinery as regular parsing—no special case handling needed.
- **Memoization**: Sub-parses benefit from the parser's existing memoization of rule calls and positions, preventing redundant work.
- **Lazy Evaluation**: Sub-parses only proceed as far as necessary to determine success/failure; they don't compute full parse trees.
- **No Rollback Cost**: Unlike traditional PEG backtracking or parser combinators, there's no parsing state to save and restore—frames naturally progress through the work queue.
- **Token History**: Frames at lagging positions can access already-parsed tokens via a linked-list history, eliminating the need to re-process characters.

**Example: Internal Flow**

```dart
final grammar = Grammar(() {
  // Match 'a' only if followed by 'b'
  return Rule('test', () =>
    Token.char('a').and() >> Token.char('b')
  );
});

final parser = SMParser(grammar);
parser.recognize('ab');  // true
```

**What happens internally:**

1. Parser is at position 0, encounters `Token.char('a').and()`
2. A sub-parse frame is spawned: "can 'b' match at position 1?"
3. The sub-parse frame is enqueued in the work queue with position = 1
4. After processing position 0, the work queue pops the sub-parse frame (position 1)
5. Sub-parse frame transitions are resolved: does the state machine accept 'b' at position 1?
6. Sub-parse succeeds, `PredicateTracker` is marked as matched
7. Waiting parent frame (for the AND predicate) is resumed
8. Main parse allows `Token.char('a')` to match at position 0
9. Parser continues with `Token.char('b')` at position 1
10. Result: true (entire input matched)

---

## Code Generation

### Generate Dart Parser from Grammar File

Create a `.glush` grammar file:

```glush
# simple.glush
number = /[0-9]+/ ;
expr =
  number
  | expr "+" expr
  ;
```

Generate a standalone parser:

```dart
import 'package:glush/glush.dart';

void main() {
  final grammarText = '''
    number = /[0-9]+/ ;
    expr =
      number
      | expr "+" expr
      ;
  ''';

  // Generate Dart code
  final gfParser = GrammarFileParser(grammarText);
  final grammarFile = gfParser.parse();

  final codegen = GrammarCodeGenerator(grammarFile);
  final dartCode = codegen.generateGrammarFile();

  print(dartCode);  // Full Dart grammar class

  // Or generate standalone (no dependency on glush):
  final standalone = codegen.generateStandaloneGrammarFile();
  File('my_parser.dart').writeAsStringSync(standalone);
}
```

### Use Generated Parser

The generated parser is a complete Dart class with no dependencies:

```dart
import 'my_parser.dart';

void main() {
  final parser = MyGrammarParser();

  if (parser.recognize('123+456')) {
    print('Valid');
  }

  final trees = parser.parseAll('123+456').toList();
  for (final tree in trees) {
    print(tree.toTreeString());
  }
}
```

### Grammar File Format

```glush
# Comments with #
# Rules: name = pattern ;

# Tokens
digit = [0-9] ;
letter = [a-zA-Z] ;
word = letter+ ;

# Backslash literals are supported
identifier = \w+ ;
whitespace = \s* ;
numberInfo = \d+ ;

# Sequences
pair = "(" expr ")" ;

# Choices
value = number | identifier ;

# Repetition
csv = value ("," value)* ;

# With precedence levels (for code generation)
expr =
  6| $add expr "+" expr
  7| $mul expr "*" expr
  11| NUMBER
  ;
```

---

## Examples

### 1. JSON Parser

```dart
import 'package:glush/glush.dart';

void main() {
  final grammar = Grammar(() {
    late Rule value, array, object, string, number;

    // Whitespace
    final ws = Token.char(' ').star();  // spaces

    // Literals
    final nullVal = Pattern.string('null')
      .withAction<Null>((_, __) => null);

    final trueVal = Pattern.string('true')
      .withAction<bool>((_, __) => true);

    final falseVal = Pattern.string('false')
      .withAction<bool>((_, __) => false);

    // Number: simplified (integer only)
    number = Rule('number', () =>
      Token.char('-').maybe() >>
      Token.charRange('0', '9').plus()
        .withAction<int>((span, _) => int.parse(span))
    );

    // String: "..." (simplified)
    string = Rule('string', () =>
      Token.char('"') >>
      (Token.char('\\').not() >> Token.charRange(' ', '~')).star() >>
      Token.char('"')
        .withAction<String>((span, _) => span.substring(1, span.length - 1))
    );

    // Array: [ value, value, ... ]
    array = Rule('array', () =>
      Token.char('[') >> ws >>
      (value() >> (Token.char(',') >> ws >> value()).star()).maybe() >>
      ws >> Token.char(']')
        .withAction<List>((_, _) => [])  // Simplified
    );

    // Object: { "key": value, ... }
    object = Rule('object', () =>
      Token.char('{') >> ws >>
      (string() >> ws >> Token.char(':') >> ws >> value() >>
       (Token.char(',') >> ws >> string() >> ws >> Token.char(':') >> ws >> value()).star()
      ).maybe() >>
      ws >> Token.char('}')
        .withAction<Map>((_, _) => {})  // Simplified
    );

    // Value: any JSON value
    value = Rule('value', () =>
      string() |
      number() |
      array() |
      object() |
      nullVal |
      trueVal |
      falseVal
    );

    return value();
  });

  final parser = SMParser(grammar);

  print(parser.recognize('[1, 2, 3]'));              // true
  print(parser.recognize('{"key": "value"}'));       // true
  print(parser.recognize('{"key": [1, 2, 3]}'));    // true
}
```

### 2. Configuration File Parser

```dart
final grammar = Grammar(() {
  late Rule config, setting, key, value;

  // Whitespace: space or tab
  final ws = (Token.char(' ') | Token.char('\t')).star();

  // Key: lowercase letters
  key = Rule('key', () =>
    Token.charRange('a', 'z').plus()
      .withAction<String>((span, _) => span)
  );

  // Value: alphanumeric
  value = Rule('value', () =>
    Token.charRange('0', 'z').plus()  // Simplified
      .withAction<String>((span, _) => span)
  );

  // Setting: key = value
  setting = Rule('setting', () =>
    key() >> ws >> Token.char('=') >> ws >> value()
      .withAction<Map>((_, c) => {c[0]: c[2]})
  );

  // Config: multiple settings
  config = Rule('config', () =>
    setting() >> (Token.char('\n') >> setting()).star()
  );

  return config();
});

final parser = SMParser(grammar);
parser.recognize('name = value\nhost = localhost');  // true
```

### 3. Expression Evaluator with Precedence

See the "Operator Precedence" section above for a complete example.

---

## Best Practices

### 1. **Use Recursive Rules for Precedence**

Instead of explicit precedence levels, use separate rules for each level:

```dart
// ✅ Good
expr = Rule('expr', () =>
  term() |
  (expr() >> Token.char('+') >> term())
);

term = Rule('term', () =>
  factor() |
  (term() >> Token.char('*') >> factor())
);

// ❌ Harder to read
expr = Rule('expr', () =>
  (expr() >> Token(RangeToken(42, 42)) >> expr()).atLevel(7) |
  (expr() >> Token(RangeToken(43, 43)) >> expr()).atLevel(6)
);
```

### 2. **Name Your Rules Meaningfully**

```dart
// ✅ Clear intent
final identifier = Rule('identifier', () =>
  Token(RangeToken(97, 122)).plus()
);

// ❌ Vague
final r1 = Rule('r1', () =>
  Token(RangeToken(97, 122)).plus()
);
```

### 3. **Attach Actions Close to Tokens**

```dart
// ✅ Clear where value comes from
Token.charRange('0', '9').plus()
  .withAction<int>((span, _) => int.parse(span))

// Less clear
(Token.charRange('0', '9').plus() >> Eps())
  .withAction<int>((span, _) => int.parse(span.trim()))
```

### 4. **Flatten Repetitions in Actions**

```dart
// ✅ Readable helper
List<T> flattenRepetition<T>(ParseDerivation tree, T Function(ParseDerivation) eval) {
  const List<T> result = [];
  while (tree.children.isNotEmpty) {
    result.add(eval(tree.children[0]));
    tree = tree.children.length > 1 ? tree.children[1] : null;
  }
  return result;
}

// Apply it
.withAction<List<int>>((_, c) => flattenRepetition(c[1], (t) => evaluate(t)));
```

### 5. **Choose the Right Parsing Method**

- **`recognize()`** — Validation only
- **`enumerateAllParses()`** — All trees, lazy, small input
- **`parseWithForest()`** — Ambiguous grammars, can afford O(n³)
- **`enumerateAllParsesWithResults()`** — Evaluation, lazy
- **`parseWithForest()` + `enumerateForestWithResults()`** — Evaluation, forest

---

## API Reference

### Grammar (`lib/src/grammar.dart`)

```dart
class Grammar {
  Grammar(Pattern Function() buildRule);
  // Defines a grammar from a pattern-building function
}

class Rule {
  Rule(String name, Pattern Function() buildPattern);
  // A named rule in the grammar
}
```

### Patterns (`lib/src/patterns.dart`)

```dart
abstract class Pattern {}

// Tokens (match single chars)
class Token extends Pattern { /* ... */ }
// Token helpers for common patterns
// Token.char('x') — single character
// Token.charRange('a', 'z') — character range

// Sequences
extension Seq on Pattern {
  Pattern operator >>(Pattern other);
}

// Alternation
extension Or on Pattern {
  Pattern operator |(Pattern other);
}

// Repetition
extension Rep on Pattern {
  Pattern star();     // 0+
  Pattern plus();     // 1+
  Pattern maybe();    // 0-1
}

// Predicates
extension Pred on Pattern {
  Pattern and();      // Lookahead
  Pattern not();      // Negative lookahead
}

// Semantic actions
extension Action<T> on Pattern {
  Action<T> withAction<T>(T Function(String span, List<dynamic> children) callback);
}

// Markers
class Marker extends Pattern {
  Marker(String name);
}

// Evaluator
class Evaluator<T> {
  Evaluator(Map<String, dynamic Function()> Function(R Function<R>() consume) factory);
  (T, List<String>) evaluate(List<String> marks);
}

// Precedence
extension PrecedenceLevel on Pattern {
  Pattern atLevel(int level);
}

// Rules
class RuleCall extends Pattern {
  RuleCall(String name, Rule rule, {int? minPrecedenceLevel});
}
```

### Parser (`lib/src/sm_parser.dart`)

```dart
class SMParser {
  SMParser(Grammar grammar);

  // Fast validation
  bool recognize(String input);

  // Marks-based parsing
  ParseOutcome parse(String input);

  // Ambiguous parsing with efficient GSS
  ParseOutcome parseAmbiguous(String input, {bool captureTokensAsMarks = false});

  // Full parse forest (SPPF)
  ParseOutcome parseWithForest(String input);

  // Streaming parse forest
  Future<ParseOutcome> parseWithForestAsync(
    Stream<String> input,
    {int lookaheadWindowSize = 1048576},
  );

  // Tree enumeration
  Iterable<ParseDerivation> enumerateAllParses(String input);

  Iterable<ParseDerivationWithValue<T>> enumerateAllParsesWithResults<T>(String input);

  // Forest evaluation
  Iterable<ParseDerivationWithValue<T>> enumerateForestWithResults<T>(
    ParseForestSuccess forest,
    String input,
  );
}

// Parse result types
sealed class ParseOutcome {}
final class ParseSuccess extends ParseOutcome {
  final ParserResult result;
}
final class ParseError extends ParseOutcome {
  final int position;
}
final class ParseAmbiguousForestSuccess extends ParseOutcome {
  final GlushList<Mark> forest;
}
final class ParseForestSuccess extends ParseOutcome {
  final ParseForest forest;
}

// Parse forest analysis
class ParseForest {
  int countNodes();
  int countFamilies();
  Map<String, Object?> countDerivationsWithSCC();
  Iterable<ParseDerivation> extract();
}
```

### Parse Trees (`lib/src/patterns.dart`)

```dart
class ParseDerivation {
  final String symbol;                    // Rule name
  final int start;                        // Start position
  final int end;                          // End position
  final List<ParseDerivation> children;   // Child nodes

  String getMatchedText(String input) => input.substring(start, end);
  String toTreeString([String? input]);
}

class ParseDerivationWithValue<T> {
  final ParseDerivation tree;
  final T value;
}
```

### Mark Collection (`lib/src/mark.dart`)

```dart
sealed class Mark {}

class NamedMark extends Mark {
  final String name;
  final int position;
  // Marks a named position
}

class StringMark extends Mark {
  final String value;
  final int position;
  // Marks a string value at position
}
```

### Code Generation (`lib/src/grammar_codegen.dart`)

```dart
class GrammarCodeGenerator {
  GrammarCodeGenerator(GrammarFile grammarFile);

  String generateGrammarFile();                    // Dependent on glush
  String generateStandaloneGrammarFile();          // Fully standalone
}

// Helper
String generateStandaloneGrammarDartFile(String grammarText);
```

### Grammar File Format (`lib/src/grammar_file_*.dart`)

```dart
class GrammarFileParser {
  GrammarFileParser(String grammarText);
  GrammarFile parse();
}

class GrammarFile {
  final List<RuleDefinition> rules;
}

class RuleDefinition {
  final String name;
  final Pattern pattern;
  final Map<Pattern, int> precedenceLevels;  // For "N|" syntax
}
```

---

## Performance Notes

- **Recognition:** O(n) time, O(n) space
- **Tree enumeration:** O(n²) memoization, O(depth) per tree
- **Forest:** O(n³) to build, O(D) to extract D trees
- **Semantic actions:** Bottom-up evaluation, non-invasive

Choose `enumerateAllParses()` for interactive/streaming use. Choose `parseWithForest()` for batch processing of ambiguous grammars.

---

## License

MIT License — See [LICENSE](LICENSE) file.

---

For questions, examples, and more — see `/example` directory in the repository.
