# Glush — Versatile Parser Toolkit for Dart

A powerful, flexible parsing library for Dart that supports **CFG Parsing**, **state machines**, **parse forests**, and **parser code generation**. Build anything from simple tokenizers to complex expression parsers with minimal boilerplate.

> Note: This library and its tooling were developed with the help of AI-assisted generation.

**Key Features:**
- 🎯 **Pattern-based DSL** — Define grammars using Dart-native operators (`>>`, `|`, `*`, `+`, `?`)
- 🔍 **Multiple parsing methods** — Recognition, parse tree enumeration, full parse forests (SPPF)
- 📍 **Mark collection** — Track parse positions and capture spans with named and string marks
- ⚙️ **Semantic actions** — Attach callbacks to patterns to evaluate or transform results during parsing
- 📊 **Operator precedence** — Support both natural (recursive structure) and explicit (precedence levels) precedence
- 🔧 **Code generation** — Generate standalone Dart parsers from grammar definitions
- 🌳 **Parse forest support** — Handle ambiguous grammars efficiently with SPPF (Shared Packed Parse Forest)
- ✨ **Lookahead predicates** — Use AND (`&`) and NOT (`!`) for contextual matching without consuming input
- ⚡ **No external dependencies** — Pure Dart implementation

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Patterns and Operations](#patterns-and-operations)
4. [Parsing Methods](#parsing-methods)
5. [Mark Collection](#mark-collection)
6. [Semantic Actions](#semantic-actions)
7. [Operator Precedence](#operator-precedence)
8. [Lookahead Predicates](#lookahead-predicates)
9. [Code Generation](#code-generation)
10. [Examples](#examples)
11. [Best Practices](#best-practices)
12. [API Reference](#api-reference)

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
      Call(number) |
      (Token.char('(') >>
       Call(expr) >>
       Token.char(')'))
        .withAction<int>((_, children) => children[1])
    );

    // term = factor (('*' | '/') factor)*
    term = Rule('term', () =>
      Call(factor) |
      (Marker('mul') >> Call(term) >> Token.char('*') >> Call(factor))
        .withAction<int>((_, children) => children[1] * children[3]) |
      (Marker('div') >> Call(term) >> Token.char('/') >> Call(factor))
        .withAction<int>((_, children) => children[1] ~/ children[3])
    );

    // expr = term (('+' | '-') term)*
    expr = Rule('expr', () =>
      Call(term) |
      (Marker('add') >> Call(expr) >> Token.char('+') >> Call(term))
        .withAction<int>((_, children) => children[1] + children[3]) |
      (Marker('sub') >> Call(expr) >> Token.char('-') >> Call(term))
        .withAction<int>((_, children) => children[1] - children[3])
    );

    return Call(expr);
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
    Call(term) >> (Token.char('+') >> Call(term)).star()
  );

  term = Rule('term', () =>
    Token.charRange('0', '9').plus()
  );

  return Call(expr);  // Return the start rule
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
| Call | `Call(rule)` | Reference another rule |
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
- Star with zero matches: empty children list
- Star with matches: `[first_item, star_of_rest]` (recursive)
- Plus: Always at least 2 children

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
    Call(digit) >> Call(digit).star()
  );

  return Call(number);
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

---

## Comparison: `enumerateAllParses()` vs `parseWithForest()`

| Aspect | `enumerateAllParses()` | `parseWithForest()` |
|--------|--|--|
| **Time to first tree** | Fast: O(depth) | Slow: O(n³) |
| **Time for all D trees** | O(n² + D×K) | O(n³ + D) |
| **Laziness** | ✅ Lazy | ❌ Eager |
| **Space** | O(n²) | O(F) forest nodes |
| **Best for** | Small input, few trees | Highly ambiguous, all trees |

---

## Mark Collection

**Marks** track parse positions and named spans during parsing. Use them to capture semantic information about where things happen in the input.

### Named Marks

Name the position where something occurs:

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

  return Call(expr);
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

  return Call(Rule('kw', () => keyword));
});
```

### Mark Applications

**Common uses:**
- **Syntax highlighting:** Mark token boundaries
- **Error recovery:** Know exactly where parsing failed
- **Semantic actions:** Capture operator positions for AST
- **Location tracking:** Line/column info for error messages

Example with location info:

```dart
class Token {
  final String value;
  final int line;
  final int column;

  Token(this.value, this.line, this.column);
}

// Use marks to build position-aware AST:
final opToken = Marker('op_start') >>
    Pattern.string('+') >>
    Marker('op_end')
      .withAction<Token>((_, marks) {
        // marks contains the marked positions
        return Token('+', line, column);
      });
```

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
    Call(number) |
    (Call(term) >> Token.char('*') >> Call(number))
      .withAction<int>((_, c) => c[0] * c[2])
  );

  expr = Rule('expr', () =>
    Call(term) |
    (Call(expr) >> Token.char('+') >> Call(term))
      .withAction<int>((_, c) => c[0] + c[2])
  );

  return Call(expr);
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
    Call(number) |
    (Call(term) >> Token.char('*') >> Call(number))
      .withAction<BinOpExpr>((_, c) => BinOpExpr('*', c[0], c[2]))
  );

  expr = Rule('expr', () =>
    Call(term) |
    (Call(expr) >> Token.char('+') >> Call(term))
      .withAction<BinOpExpr>((_, c) => BinOpExpr('+', c[0], c[2]))
  );

  return Call(expr);
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
    Call(number) |
    (Token.char('(') >> Call(expr) >> Token.char(')'))
  );

  // Medium precedence: * and /
  term = Rule('term', () =>
    Call(factor)
      .withAction<int>((_, c) => c[0]) |
    (Call(term) >> Token.char('*') >> Call(factor))
      .withAction<int>((_, c) => c[0] * c[2]) |
    (Call(term) >> Token.char('/') >> Call(factor))
      .withAction<int>((_, c) => c[0] ~/ c[2])
  );

  // Lowest precedence: + and -
  // Left-recursive for left-associativity: expr → expr '+' term
  expr = Rule('expr', () =>
    Call(term)
      .withAction<int>((_, c) => c[0]) |
    (Call(expr) >> Token.char('+') >> Call(term))
      .withAction<int>((_, c) => c[0] + c[2]) |
    (Call(expr) >> Token.char('-') >> Call(term))
      .withAction<int>((_, c) => c[0] - c[2])
  );

  return Call(expr);
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
  Call(expr) >> Token.char('-') >> Call(term)  // Left recursion
);

// RIGHT-ASSOCIATIVE:
// a ^ b ^ c = a ^ (b ^ c)
expr = Rule('expr', () =>
  Call(term) >> Token.char('^') >> Call(expr)  // Right recursion
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
  return (Marker('pair') >> Call(expr) >> Token.char('=') >> Token.char('>') >> Call(expr))
    .atLevel(1) |
    (Marker('add') >> Call(expr) >> Token.char('+') >> Call(expr))
      .atLevel(2) |
    (Marker('mul') >> Call(expr) >> Token.char('*') >> Call(expr))
      .atLevel(3) |
    Token.charRange('0', '9').plus()
      .atLevel(11);
});

// With precedence constraints (filter which alternatives can be called):
expr = Rule('expr', () {
  return Call(expr, minPrecedenceLevel: 2) >> Token.char('+') >> Call(expr, minPrecedenceLevel: 3) |
         Call(expr, minPrecedenceLevel: 3) >> Token.char('*') >> Call(expr);
});
```

---

## Lookahead Predicates

Test conditions without consuming input. Use AND (`&`) and NOT (`!`) predicates:

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
      (Call(value) >> (Token.char(',') >> ws >> Call(value)).star()).maybe() >>
      ws >> Token.char(']')
        .withAction<List>((_, _) => [])  // Simplified
    );

    // Object: { "key": value, ... }
    object = Rule('object', () =>
      Token.char('{') >> ws >>
      (Call(string) >> ws >> Token.char(':') >> ws >> Call(value) >>
       (Token.char(',') >> ws >> Call(string) >> ws >> Token.char(':') >> ws >> Call(value)).star()
      ).maybe() >>
      ws >> Token.char('}')
        .withAction<Map>((_, _) => {})  // Simplified
    );

    // Value: any JSON value
    value = Rule('value', () =>
      Call(string) |
      Call(number) |
      Call(array) |
      Call(object) |
      nullVal |
      trueVal |
      falseVal
    );

    return Call(value);
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
    Call(key) >> ws >> Token.char('=') >> ws >> Call(value)
      .withAction<Map>((_, c) => {c[0]: c[2]})
  );

  // Config: multiple settings
  config = Rule('config', () =>
    Call(setting) >> (Token.char('\n') >> Call(setting)).star()
  );

  return Call(config);
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
  Call(term) |
  (Call(expr) >> Token.char('+') >> Call(term))
);

term = Rule('term', () =>
  Call(factor) |
  (Call(term) >> Token.char('*') >> Call(factor))
);

// ❌ Harder to read
expr = Rule('expr', () =>
  (Call(expr) >> Token(RangeToken(42, 42)) >> Call(expr)).atLevel(7) |
  (Call(expr) >> Token(RangeToken(43, 43)) >> Call(expr)).atLevel(6)
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

// Precedence
extension PrecedenceLevel on Pattern {
  Pattern atLevel(int level);
}

class Call extends Pattern {
  Call(Rule rule, {int? minPrecedenceLevel});
}

// Rules
class RuleCall extends Pattern {
  RuleCall(Rule rule, {int? minPrecedenceLevel});
}
```

### Parser (`lib/src/sm_parser.dart`)

```dart
class SMParser {
  SMParser(Grammar grammar);

  bool recognize(String input);
  
  Iterable<ParseDerivation> enumerateAllParses(String input);
  
  Iterable<ParseDerivationWithValue<T>> enumerateAllParsesWithResults<T>(String input);
  
  ParseOutcome<Never> parseWithForest(String input);
  
  Iterable<ParseDerivationWithValue<T>> enumerateForestWithResults<T>(
    ParseForestSuccess forest,
    String input,
  );
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
