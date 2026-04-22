# Glush: A Generalized Parsing Toolkit for Dart

[![Pub Version](https://img.shields.io/pub/v/glush?color=blue)](https://pub.dev/packages/glush)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Glush is a **push-based CFG / CSG (context-sensitive)** parsing toolkit for Dart, designed from the ground up to handle complex, ambiguous, and data-driven grammars with ease. It combines the expressive power of context-free/sensitive grammars with a high-performance state-machine runtime to provide a "zero-overhead" parsing experience.

## Why Glush?

Traditional parsers (LL, LR, PEG) often force you to refactor your grammar into a specific shape, losing clarity and intent. Glush liberates you from these constraints:

- 🚀 **Ambiguity is First-Class**: Parse any context-free grammar, even highly ambiguous ones. Obtain all possible derivations in a semantic parse forest.
- 🧠 **Context-Sensitive (CSG) Logic**: Rules can take parameters and use `if (guard)` expressions for sophisticated data-driven parsing.
- ⚡ **Push-Based Performance**: Hybrid architecture using a push-based state-machine transition model. It optimizes for deterministic paths while maintaining generalized power where needed.
- 💎 **Ergonomic Evaluation**: Stop indexing children by position (`children[0][1]`). Use the label-driven `Evaluator<T>` API to pull data by name.

---

## 🏗️ Getting Started

Add Glush to your `pubspec.yaml`:

```yaml
dependencies:
  glush: ^latest
```

### Quick Example: Simple Math

```dart
import 'package:glush/glush.dart';

void main() {
  final parser = r'''
    expr =
       1 | $add left:expr '+' right:expr
       2 | $num [0-9]+;
  '''.toSMParser();

  final input = '1 + 2 + 3';
  final outcome = parser.parse(input);

  if (outcome is ParseSuccess) {
    // 1. Convert marks to a structured tree
    final tree = StructuredEvaluator().evaluate(outcome.rawMarks, input: input);

    // 2. Interpret with a typed evaluator
    final evaluator = Evaluator<int>({
      'add': (ctx) => ctx<int>('left') + ctx<int>('right'),
      'num': (ctx) => int.parse(ctx.span),
    });

    print(evaluator.evaluate(tree)); // Output: 6
  }
}
```

---

## 📝 Grammar DSL Reference

Glush uses a powerful string-based DSL that supports virtually every modern parsing primitive.

### 🧩 Pattern Operators

| Operator        | Syntax                 | Description                                              |
| :-------------- | :--------------------- | :------------------------------------------------------- |
| **Sequence**    | `A B`                  | Matches `A` followed by `B`.                             |
| **Choice**      | `A \| B`               | Matches either `A` or `B` (Generalized).                 |
| **Lookahead**   | `&A` / `!A`            | Positive or Negative lookahead. Doesn't consume input.   |
| **Repetition**  | `*`, `+`, `?`          | Zero-or-more, one-or-more, or optional.                  |
| **Possessive**  | `*!`, `+!`             | Deterministic repetition (won't backtrack once matched). |
| **Literals**    | `'abc'`, `"abc"`       | Exact string matching.                                   |
| **Ranges**      | `[a-z]`, `[0-9A-F]`    | Character class matching.                                |
| **Wildcard**    | `.`                    | Matches any single character.                            |
| **Terminals**   | `^` (Start), `$` (EOF) | Matches the beginning or end of input.                   |

### 🏷️ Metadata & Organization

| Feature           | Syntax       | Description                                               |
| :---------------- | :----------- | :-------------------------------------------------------- |
| **Label**         | `id:Pattern` | Assigns an identifier to a pattern for the Evaluator API. |
| **Mark**          | `$id`        | Emits a semantic marker in the output stream.             |
| **Group**         | `( ... )`    | Standard grouping for operator precedence.                |
| **Precedence**    | `expr ^ N`   | Forces an expression to match at precedence level `N`.    |
| **Associativity** | `N \| Alt`   | Defines an alternative starting at precedence level `N`.  |

---

## 🤖 Data-Driven Grammars (CSG)

Glush is unique in its support for **parameterized rules** and **guards**. This allows you to implement context-sensitive behavior (like XML tag matching or indentation tracking) directly in the grammar.

### Example: XML Tag Matching

```dart
final grammar = r'''
  element = openTag body closeTag(tag);

  openTag = '<' tag:name '>';

  # Parameters are passed down the call stack
  closeTag(open) = '</' close:name '>' if (open == close) '';

  name = [a-z]+;
  body = [^<]*;
'''.toSMParser();

print(grammar.recognize('<book>Glush</book>'));    // true
print(grammar.recognize('<book>Glush</author>'));  // false
```

---

## 🏆 Advanced Ambiguity Handling

As a generalized parser, Glush doesn't fail on left-recursion or ambiguous "conflicts". It simply explores all paths using its push-based state machine.

```dart
final parser = r'''
  S = $TWO S S | $ONE 's';
'''.toSMParser();

// "sss" can be parsed as (s(ss)) or ((ss)s)
final outcome = parser.parseAmbiguous('sss');

if (outcome is ParseAmbiguousSuccess) {
  for (var path in outcome.forest.allMarkPaths()) {
    print(path.evaluateStructure('sss')); // Prints each unique derivation tree
  }
}
```

---

## 🧪 Semantic Evaluation

The `Evaluator<T>` API is the heart of Glush's ergonomics. It allows you to transform raw parse marks into your domain-specific objects (AST nodes, JSON, etc.) without fragile tree-walking code.

```dart
final evaluator = Evaluator<MyNode>({
  'rule_name': (ctx) {
    // Read labeled children by name
    final name = ctx<String>('name_label');

    // Read the current text span
    final text = ctx.span;

    // Check for optional matches
    if (ctx.optional('opt_label') case var value?) { ... }

    return MyNode(name, text);
  },
});
```

---

## 🛠️ Performance Features

1.  **Push-Based State Machine**: Glush avoids the massive GSS overhead of traditional GLL/GLR for deterministic parts of your grammar by using an efficient state-machine transition model.
2.  **Streaming Interface**: Support for `parseWithForestAsync(stream)` allows you to parse Multi-GB files without loading them into memory.
3.  **GlushList**: A specialized, low-allocation internal data structure for managing large forests with identity-based interning and identity-based deduplication.

---

## 📡 Roadmap & Status

Glush is actively maintained and currently powering several internal DSL projects. We are currently focusing on:

- [ ] Stabilizing the Forest/BSR hygiene for complex lookaheads.
- [ ] Improved error reporting with "expected" token suggestions.
- [ ] Code generation backend for even faster execution.

## 📄 License

MIT. See [LICENSE](LICENSE).
