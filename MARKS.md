# Marks in Glush

Marks are semantic annotations used during parsing to capture information from the input. Glush provides several ways to generate and manage marks.

## Types of Marks

Glush uses two main types of marks:
- **NamedMark**: Created by `$nameTerm` or explicit `Marker` patterns. They carry a name and the position where they occurred.
- **StringMark**: Created automatically for certain token matches. They carry the matched string and its position.

## Automatic Mark Capture

When using `parseAmbiguous` or `parseWithForest`, Glush automatically captures tokens as `StringMark` objects under specific conditions to avoid cluttering the mark list with redundant information.

### When Marks ARE Saved (by default)

1. **Named Markers**: Any pattern prefixed with `$` (e.g., `$ONE`, `$sum`) ALWAYS creates a `NamedMark`.
2. **Variable Tokens**: Tokens that can match multiple possibilities automatically capture their value as a `StringMark`. These include:
   - **Range Tokens**: `[a-z]`, `[0-9]`
   - **Any Token**: `.`
   - **Comparison Tokens**: `<100`, `>0`
3. **Explicit Capture**: If you call `parseAmbiguous(input, captureTokensAsMarks: true)`, EVERY token match will result in a `StringMark`.

### When Marks ARE NOT Saved (by default)

1. **Exact Tokens**: Single character literals like `'a'`, `'='`, or `'s'` do NOT create a `StringMark` by default. Since the character matched is already known from the grammar, it is omitted to save memory and simplify the mark list.
2. **Literal Strings**: In grammar files, literal strings like `"hello"` are compiled into a sequence of `ExactToken`s. These do not produce `StringMark`s by default.

## Examples

### Example 1: `ExactToken` vs `RangeToken`

In this example, the grammar has one rule matching an exact character and another matching a range.

```dart
// Grammar:
// main = exact | range
// exact = $exact 'a'
// range = $range [0-9]

// Parsing 'a':
// rawMarks: [NamedMark('exact', 0)]
// Short marks: ["exact"]

// Parsing '1':
// rawMarks: [NamedMark('range', 0), StringMark('1', 0)]
// Short marks: ["range", "1"]
```

### Example 2: Forcing Capture

You can force capture of all tokens including exact literals.

```dart
// Parsing 'a' with captureTokensAsMarks: true
// rawMarks: [NamedMark('exact', 0), StringMark('a', 0)]
// Short marks: ["exact", "a"]
```

## Evaluating Marks

The `Evaluator` class consumes marks from the list. When it encounters a string that isn't a named marker, it yields it as a value.

```dart
final evaluator = Evaluator(($) => {
  'num': () => $<String>().trim(), // Expects a StringMark to follow 'num'
});
```

If a string mark is "missing" (because it was an `ExactToken`), the evaluator will instead consume the NEXT mark in the list, which often leads to errors or unexpected results if the handler expects a string value from the input.
