# Glush — Versatile Parser Toolkit for Dart

A powerful, high-performance parsing library for Dart that combines the flexibility of **Context-Free Grammars (CFG)** with the efficiency of **State Machines**. Glush is designed for everything from simple expression evaluators to complex, ambiguous language processors.

---

## Key Features

- **🚀 State-Machine Powered**: Based on a generalized Glushkov construction that compiles grammars into efficient automata.
- **🌳 Shared Packed Parse Forest (SPPF)**: Handles highly ambiguous grammars with cubic worst-case time and space complexity.
- **🛡️ Type-Safe Evaluation**: Modern `Evaluator<T>` API with structured `ParseResult` trees and a streaming `NodeIterator`.
- **🏗️ Graph-Structured Stack (GSS)**: Efficiently navigates ambiguity during parsing without exponential memory growth.
- **⚡ Zero Dependencies**: Pure Dart implementation with no external requirements.
- **📶 Streaming Support**: Built-in support for processing large inputs via `parseWithForestAsync()`.

---

## Quick Start

### Basic Expression Evaluator

Glush makes it easy to define and evaluate grammars using a clean, readable DSL.

```dart
import 'package:glush/glush.dart';

void main() {
  // 1. Define the grammar
  final parser = r"""
    expr = 6| $add expr^6 '+' expr^7
           7| $mul expr^7 '*' expr^8
          10| '(' expr ')'
          11| $n [0-9]+
  """.trim().toSMParser();

  // 2. Define the evaluator
  final evaluator = Evaluator<int>({
    'add': (eval, node, it) => eval.evaluateChildren(it) + eval.evaluateChildren(it),
    'mul': (eval, node, it) => eval.evaluateChildren(it) * eval.evaluateChildren(it),
    'n': (eval, node, it) => int.parse(node.span),
  });

  // 3. Parse and Evaluate
  final result = parser.parse('1 + 2 * 3');
  if (result is ParseSuccess) {
    // Transform flat marks into a structured tree
    final tree = StructuredEvaluator().evaluate(result.result.rawMarks);
    // Evaluate the tree
    final value = evaluator.evaluate(tree);
    print('Result: $value'); // Output: 7
  }
}
```

---

## Core Concepts

### 1. Grammars and Patterns
Grammars can be defined using the **String DSL** (as seen above) or the **Dart DSL**.

```dart
// Dart DSL Example
final grammar = Grammar(() {
  late Rule expr, term;
  expr = Rule('expr', () => term() >> (Token.char('+') >> term()).star());
  term = Rule('term', () => Token.charRange('0', '9').plus());
  return expr();
});
```

### 2. The Marks System
Glush decouples parsing from evaluation. The parser emits a stream of **Marks** (labels and token values), which can then be processed into:
- A flat list of semantic results.
- A **Structured Tree** (`ParseResult`) for easy navigation.

### 3. Ambiguity and SPPF
For ambiguous grammars (like "dangling else"), Glush uses an **SPPF** to store all possible parse trees efficiently. You can enumerate all derivations or extract specific paths.

```dart
final result = parser.parseAmbiguous('input');
if (result is ParseAmbiguousForestSuccess) {
  for (final path in result.forest.allPaths()) {
    final tree = StructuredEvaluator().evaluate(path);
    print(evaluator.evaluate(tree));
  }
}
```

---

## Parsing Methods Comparison

| Method | Best For | Complexity | Output |
|--------|----------|------------|--------|
| `recognize()` | Fast validation | O(n) | `bool` |
| `parse()` | Standard unambiguous grammars | O(n) | `ParseSuccess` (Marks) |
| `parseAmbiguous()` | Ambiguous grammars with GSS | O(n) | `ParseAmbiguousForestSuccess` |
| `parseWithForest()` | Full SPPF construction | O(n³) | `ParseForestSuccess` |
| `parseWithForestAsync()` | Streaming large inputs | O(n³) | `Future<ParseForestSuccess>` |

---

## Advanced Features

### Structured Evaluation
The `Evaluator<T>` API provide a "porting-safe" way to write interpreters.
- **`NodeIterator`**: A stateful iterator used by handlers to consume children.
- **Auto-flattening**: Automatically handles redundant rule-call wrappers, keeping your handlers focused on semantic data.
- **Type Safety**: No more `dynamic` or `List<dynamic>` casts.

### Operator Precedence
Glush supports natural precedence levels in the String DSL using the `precedence|` syntax. This automatically translates to the correct grammar transformation behind the scenes.

---

## License
MIT License. See `LICENSE` for details.
