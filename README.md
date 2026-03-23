# Glush: A Generalized Parsing Toolkit for Dart

Glush is a parser toolkit for Dart focused on three goals:

1. Expressive grammar authoring (string DSL + Dart DSL)
2. Practical ambiguity handling (forest-based parsing)
3. Ergonomic semantic evaluation (label-driven evaluator API)

It is designed for language tooling, DSLs, config parsers, and experimental parsing research.

## What The Toolkit Has

### Grammar Authoring
- String DSL (`toSMParser()`)
- Dart DSL (`Grammar`, `Rule`, `Pattern`)
- Labels (`name:pattern`)
- Markers (`$name`)
- Predicates (`&pattern`, `!pattern`)
- Precedence constraints (`expr^N`, `N| alternative`)

### Pattern Operators
- Sequence (`A B`)
- Choice (`A | B`)
- Conjunction (`A & B`)
- Repetition (`*`, `+`, `?`) with dedicated nodes in core parsing
- Character ranges (`[a-z]`), wildcards (`.`), backslash literals (`\n`, `\s`, etc.)

### Parsing Modes
- `recognize(input)` for yes/no acceptance
- `parse(input)` for marks-based output
- `parseAmbiguous(input)` for ambiguous-path mark forests
- `parseWithForest(input)` for SPPF extraction
- `parseWithForestAsync(stream)` for streaming large inputs

### Evaluation
- `StructuredEvaluator` for converting marks into a labeled `ParseResult` tree
- `Evaluator<T>` for typed semantic interpretation
- Forest-side parse-tree evaluation helpers (including evaluator bridge methods)

## What Is Special About Glush

- It treats ambiguity as a first-class problem rather than a failure mode.
- It supports both parser usage styles:
  - “Just parse and evaluate”
  - “Build and inspect a forest / enumerate derivations”
- It combines a state-machine runtime with graph-style structures (GSS/forest) for practical generalized parsing.
- It allows label-centric semantic actions that are easier to maintain than positional child indexing.

## Known Issues / Rough Edges

The project is active and still evolving. Current caveats:

- Repetition and optional operators have historically been a source of subtle ambiguity behavior.
- Forest extraction and semantic reconstruction are still being hardened; behavior may differ between:
  - mark-driven parse evaluation
  - direct forest parse-tree evaluation
- Some grammars that mix nullable branches, repetition, and lookahead predicates may need careful refactoring to avoid unintended ambiguity.
- Performance for large highly-ambiguous grammars can still be improved in both memory and throughput.

## What Is Being Done

Current stabilization work focuses on:

- Making `*`, `+`, and `?` deterministic where intended
- Improving forest/BSR hygiene for labeled and marked rules
- Aligning parse-tree evaluation APIs with mark-based evaluation semantics
- Expanding regression tests for:
  - whitespace-heavy grammars
  - optional/repetition boundary cases
  - forest evaluator correctness

## Quick Example

```dart
import 'package:glush/glush.dart';

void main() {
  final parser = r'''
    file = full:rule;
    rule = name:[a-z]+ ':' body:[a-z]+;
  '''.toSMParser();

  final outcome = parser.parse('alpha:beta');
  if (outcome is ParseSuccess) {
    final tree = StructuredEvaluator().evaluate(outcome.result.rawMarks);

    final evaluator = Evaluator<Object?>({
      'full': (ctx) => ctx<Object?>('rule'),
      'rule': (ctx) => (ctx<String>('name'), ctx<String>('body')),
      'name': (ctx) => ctx.span,
      'body': (ctx) => ctx.span,
    });

    final value = evaluator.evaluate(tree);
    print(value); // (alpha, beta)
  }
}
```

## Project Status

This project is usable and actively improved, but not yet a finished/stable parsing platform for all grammar shapes. If you depend on it in production, pin versions and run grammar-specific regression tests.

## License

MIT. See [LICENSE](LICENSE).
