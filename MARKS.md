# Marks in Glush

Marks are semantic annotations used during parsing to capture information from the input. Glush provides several ways to generate and manage marks, ranging from flat lists to structured trees.

## Labeled Patterns (Recomendated)

Labeled patterns are the most intuitive way to capture structured data. You can attach a label to any pattern using the `label:pattern` syntax in grammar files, or the `.label()` method in Dart.

```text
// Grammar file
person = name:[a-z]+ ":" age:[0-9]+;
```

```dart
// Dart DSL
final person = g.label('name', ident) >> g.token(58) >> g.label('age', digits);
```

### Structured Evaluation

When using labels, you should use `StructuredEvaluator` to process the marks. It produces a hierarchical `ParseResult` tree that allows easy access to captures by name.

```dart
final outcome = parser.parse("michael:30");
if (outcome is ParseSuccess) {
  final evaluator = StructuredEvaluator();
  final tree = evaluator.evaluate(outcome.result.rawMarks);
  
  print(tree['name'].span); // "michael"
  print(tree['age'].span);  // "30"
}
```

#### Why use Labels?
- **Hierarchical**: Labels can be nested, creating a tree structure that matches your grammar.
- **Readable**: Access data by meaningful names instead of index-based list scanning.
- **Clean**: Only the data you explicitly label is captured in the structured map (though all tokens are available in the flat `allResults` list).

## Flat Marks (Legacy/Advanced)

Glush also supports a flatter mark system using named markers and automatic token capture.

### Types of Flat Marks
- **NamedMark**: Created by `$nameTerm` or explicit `Marker` patterns. They carry a name and the position.
- **StringMark**: Created automatically for variable tokens like ranges `[a-z]` or any token `.`.

### Automatic Mark Capture

When using `SMParser`, you can enable `captureTokensAsMarks: true` to force every token match into the mark stream as a `StringMark`. By default, only "variable" tokens (non-literals) are captured to save memory.

## Types of Marks in the Stream

1. **LabelStartMark(name)**: Emitted at the start of a labeled pattern.
2. **LabelEndMark(name)**: Emitted at the end of a labeled pattern.
3. **StringMark(value)**: Emitted for matched tokens (when capture is enabled).
4. **NamedMark(name)**: Emitted for legacy `$` markers.

## Choosing an Evaluator

| Evaluator | Best For | Output |
|-----------|----------|--------|
| `StructuredEvaluator` | General purpose, nested data | `ParseResult` (Tree) |
| `Evaluator` | Simple flat grammars | `List<dynamic>` |
| Custom loop | Performance critical, low-level | Manual stream processing |

---

### Example: Nested Labels

```text
start = person:(first:ident " " last:ident);
ident = [A-Z][a-z]*;
```

```dart
final tree = evaluator.evaluate(marks);
final person = tree['person'];
print(person['first'].span); // "John"
print(person['last'].span);  // "Doe"
print(person.span);          // "John Doe"
```
