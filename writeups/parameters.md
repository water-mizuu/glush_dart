# Parameters in Glush: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Parameter Types](#parameter-types)
3. [Pattern-Level Representation](#pattern-level-representation)
4. [Grammar Syntax](#grammar-syntax)
5. [Parameter Resolution](#parameter-resolution)
6. [Materialization](#materialization)
7. [Rule Arguments](#rule-arguments)
8. [Parameter Predicates](#parameter-predicates)
9. [Memoization and Caching](#memoization-and-caching)
10. [Use Cases](#use-cases)
11. [Advanced Scenarios](#advanced-scenarios)
12. [Implementation Details](#implementation-details)

---

## Core Concept

Parameters in Glush enable **context-sensitive grammar (CSG)** by allowing rules to accept arguments and pass them through the rule-call stack. Unlike classic context-free grammars (CFGs) where rules are fixed once defined, parameterized rules in Glush can behave differently based on runtime values provided at the call site.

### Primary Purpose

Parameters serve two critical functions:

1. **Data-Driven Parsing**: Pass runtime values (strings, patterns, predicates) through the parse tree to make decisions at lower levels of the grammar.

2. **Context-Sensitive Constraints**: Enable languages like XML (where opening and closing tags must match) by threading identifying information down the parse stack.

### Key Property: Runtime Evaluation

Parameters are **evaluated at parse time** based on the call arguments, not at compile time. This means:

- A parameterized rule is not actually "compiled" until called with specific arguments
- Different calls to the same rule with different arguments produce different parsing behaviors
- Parameters can be strings (materialized into literal matches), patterns (used as subparsers), or predicates (used for constraints)

### Distinction from Regular Variables

Parameters are **not like variables in traditional programming languages**. A parameter in a Glush rule:

- Must be provided explicitly when the rule is called (no defaults)
- Flows through the call stack (parent → child)
- Cannot be modified or reassigned
- Is resolved fresh for each rule invocation

---

## Parameter Types

Glush supports three primary types of parameters:

### String Parameters

**Purpose**: Pass literal text that will be matched during parsing.

**Behavior**: A string parameter is "materialized" into a sequence of token-matching patterns at parse time. This allows dynamic construction of literal matches.

**Example**:

```dart
final grammar = r'''
  segment(delimiter) = 'x' delimiter 'y'

  start = segment(delimiter: ",")
       | segment(delimiter: ";")
'''.toSMParser();

// segment(delimiter: ",") matches "x,y"
// segment(delimiter: ";") matches "x;y"
```

**Materialization Process**:

1. When `segment(delimiter: ",")` is called, the parameter is stored as a **string argument**
2. At runtime, when the rule body needs to match the parameter, a parser chain is created for each character in the string
3. The parser chain matches the string exactly as if you had written `',' ` in the grammar

**Special Case: Empty Strings**:

Empty string parameters behave like epsilon (zero-width match):

```dart
final grammar = r'''
  optional_prefix(prefix) = prefix 'data'

  start = optional_prefix(prefix: "")
       | optional_prefix(prefix: "[")
'''.toSMParser();

// optional_prefix(prefix: "") matches "data"
// optional_prefix(prefix: "[") matches "[data"
```

### Pattern Parameters

**Purpose**: Pass structured parser patterns (rules, sequences, choices) as arguments.

**Behavior**: A pattern parameter is used directly as a subparser within the rule body. This allows rules to be **parameterized by their structure**, not just their content.

**Example**:

```dart
final grammar = r'''
  start = bracket(item: letter) digit

  bracket(item) = '[' item ']'

  letter = [a-z]
  digit = [0-9]
'''.toSMParser();

// start matches "[a5" (letter inside brackets, then digit)
// The 'item' parameter tells bracket what to expect inside
```

**Use Cases**:

- **Wrapper Rules**: Create reusable rules that can work with different content types
- **List Parsing**: Parse lists where the item type is parameterized
- **Recursive Patterns**: Pass the same rule recursively with different configurations

### Predicate Parameters

**Purpose**: Pass constraint expressions that should be evaluated at specific points.

**Behavior**: Predicate parameters are typically used within guard conditions (see [Guards Writeup](guard_conditions.md)) or as part of lookahead assertions within the rule body.

**Example**:

```dart
final grammar = r'''
  start = guarded_element(check: &[a-z])

  guarded_element(check) = check letter

  letter = [a-z]
'''.toSMParser();

// guarded_element(check: &[a-z]) only matches if followed by a letter
```

---

## Pattern-Level Representation

### Core Classes

In the Glush implementation, parameters are represented through classes in [lib/src/core/patterns.dart](lib/src/core/patterns.dart):

**ParameterRefPattern**:

```dart
class ParameterRefPattern extends Pattern {
  ParameterRefPattern(this.name);

  final String name;

  @override
  ParameterRefPattern copy() => ParameterRefPattern(name);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // A parameter reference is runtime-dependent; keep it conservative
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => false; // Runtime-dependent

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => "param($name)";
}
```

**ParameterCallPattern**:

```dart
class ParameterCallPattern extends Pattern {
  ParameterCallPattern(
    this.name,
    {
      Map<String, CallArgumentValue> arguments = const {},
      this.minPrecedenceLevel,
    }
  ) : arguments = Map<String, CallArgumentValue>.unmodifiable(arguments),
      argumentsKey = _callArgumentSourceKey(arguments),
      _argumentNames = _sortedArgumentNames(arguments.keys, const []);

  final String name;
  final Map<String, CallArgumentValue> arguments;
  final String argumentsKey;
  final List<String> _argumentNames;
  final int? minPrecedenceLevel;

  @override
  ParameterCallPattern copy() =>
      ParameterCallPattern(name, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);

  // Used to resolve argument values and cache keys
  ({Map<String, Object?> arguments, CallArgumentsKey key}) resolveArgumentsAndKey(
    CallArgumentsKey parentKey,
  ) { ... }

  @override
  String toString() => "param_call($name, args: $arguments)";
}
```

**CallArgumentValue** (Sealed Hierarchy):

```dart
sealed class CallArgumentValue {
  // String literal argument
  factory CallArgumentValue.string(String value) = StringCallArgumentValue;

  // Pattern/Rule argument
  factory CallArgumentValue.pattern(Pattern pattern) = PatternCallArgumentValue;

  // Rule argument
  factory CallArgumentValue.rule(Rule rule) = RuleCallArgumentValue;

  // Evaluate the argument in the given context
  Object? resolve(CallArgumentsContext context);
}
```

---

## Grammar Syntax

### Declaring Rule Parameters

Rules are declared with parameters using standard function-like syntax:

```dart
rule_name(param1, param2, param3) = pattern_body
```

Parameters are comma-separated and have no type declarations (types are inferred from usage).

**Example**:

```dart
// Rule with parameters
bracket(open, close) = open content close

content = [^[\]]+

// Rule without parameters
simple = 'x' 'y'
```

### Calling Parameterized Rules

Rules are called with named arguments using the call syntax:

```dart
rule_name(param1: value1, param2: value2)
```

Arguments must be **named** (not positional) and **must match parameter names** defined in the rule.

**Valid Syntax**:

```dart
// All arguments provided
bracket(open: "[", close: "]")

// With pattern arguments
filter(accept: letter)

// Mixed string and pattern arguments
wrapper(prefix: ">>", body: statement)
```

**Argument Value Types**:

1. **String Literals**: `"text"` or `'text'`
2. **Rule Names**: Rule calls understood as patterns: `letter`, `digit`
3. **Inline Patterns**: Patterns can be used directly where rule names are expected

### Forward References

Parameters can reference rules defined later in the grammar:

```dart
start = wrapper(item: undefined_rule)

undefined_rule = [0-9]

wrapper(item) = '[' item ']'
```

This works because rule parameters are resolved at parse time, not during grammar compilation.

---

## Parameter Resolution

### Calling Mechanism

When a parameterized rule is called, the following steps occur:

1. **Argument Binding**: Arguments provided at the call site are bound to parameter names
2. **Key Generation**: A unique key is generated based on the combination of arguments (for memoization)
3. **Stack Frame Creation**: A new frame in the call stack stores the argument bindings
4. **Parameter Reference Resolution**: When a `ParameterRefPattern` is encountered in the rule body, it looks up the parameter value from the current frame

### Call Stack

Parameters are stored in a **call stack frame** associated with each rule invocation. This allows nested rule calls to maintain their own parameter contexts:

```dart
// Grammar:
outer(x) = middle(x: x, y: "suffix")
middle(x, y) = inner(z: x) y
inner(z) = z

// Call: outer(x: "pre")
//   Frame 1: outer { x = "pre" }
//     Calls: middle(x: "pre", y: "suffix")
//       Frame 2: middle { x = "pre", y = "suffix" }
//         Calls: inner(z: "pre")
//           Frame 3: inner { z = "pre" }
```

### Argument Forwarding

Parameters can be forwarded through multiple levels:

```dart
start = wrapper(inner: letter)

wrapper(inner) = '(' inner ')'

letter = [a-z]
```

When `wrapper` is called with `inner: letter`, any reference to `inner` within `wrapper` resolves to the `letter` rule.

---

## Materialization

### String Materialization Process

String parameters are **materialized into parser chains** at parse time. This process is optimized to avoid unnecessary allocations:

**Single-Character Strings**:

For strings of length 1, the parser directly matches a single token:

```dart
segment(delimiter: "x") = ...
// Directly matches character 'x'
```

**Multi-Character Strings**:

For strings of length > 1, a cached parser chain is created:

```dart
segment(delimiter: "ab") = ...
// Chain: match 'a', then match 'b'
// Reuses same parser chain for all references to this parameter
```

**Empty Strings**:

Empty parameters are treated as epsilon (epsilon is produced whenever the parameter is referenced):

```dart
optional(prefix: "") = prefix 'data'
// Equivalent to: '' 'data'
// Matches just "data"
```

### Caching Strategy

To avoid repeatedly materializing the same string parameter, Glush uses a **parameter argument cache**:

- Each unique combination of (rule, arguments) is cached
- Subsequent calls with identical arguments reuse the cached materialization
- This cache survives across multiple inputs parsed with the same parser instance

**Example**:

```dart
var parser = grammar.toSMParser();
parser.parse("seg1");  // First call: segments("x") materialized and cached
parser.parse("seg2");  // Second call: Reuses cached materialization for segments("x")
```

---

## Rule Arguments

### Structured Parameter Passing

Rules can be passed as parameters, enabling **rule-level parameterization**:

```dart
pair(element) = element element

choice(left, right) = left | right

start = pair(element: letter)
      | choice(left: digit, right: letter)

letter = [a-z]
digit = [0-9]
```

### Late Binding

Rule parameters support **late binding**, allowing forward references:

```dart
start = recursive(child: recursive)

recursive(child) = '[' child ']' | 'x'
```

The `recursive` rule can reference itself through the `child` parameter, enabling flexible recursive structures.

---

## Parameter Predicates

Parameters can be used in predicates (lookahead assertions):

### Lookahead with String Parameters

```dart
probe(close) = 'a' &close close

start = probe(close: "cd")
```

When `probe(close: "cd")` is called:

1. Match 'a'
2. Look ahead to see if 'cd' matches (don't consume)
3. If lookahead succeeds, match 'cd' (consume)
4. If lookahead fails, the rule fails

### Negative Lookahead with Parameters

```dart
safe(bad) = 'a' !bad 'x'

start = safe(bad: "cd")
```

The rule succeeds if:

1. 'a' is matched
2. 'cd' does NOT match at the current position
3. 'x' is matched

---

## Memoization and Caching

### Argument-Based Memoization

When a parameterized rule is entered, the parser generates a **memoization key** based on:

1. **Rule Name**: Which rule is being called
2. **Argument Values**: The specific arguments provided
3. **Input Position**: Where in the input the rule is being called
4. **Caller Information**: The call stack context

This ensures that different argument combinations produce independent memoization entries:

```dart
// These are memoized separately:
segment(delimiter: ",")  // Memoization key includes ","
segment(delimiter: ";")  // Memoization key includes ";"
```

### Cache Invalidation

Memoized results are valid only for:

1. **The same input**: Different input strings invalidate all cached results
2. **The same parser instance**: Each new parser creation clears memoization

Memoization does **not** persist across parser instances:

```dart
var parser1 = grammar.toSMParser();
var parser2 = grammar.toSMParser();

parser1.parse("input"); // Caches results
parser2.parse("input"); // Has empty cache; recomputes
```

---

## Use Cases

### XML / Balanced Tag Matching

```dart
element = openTag body closeTag(tag)

openTag = '<' tag:name '>'

closeTag(open) = '</' close:name '>' if (open == close) ''

name = [a-z]+
body = [^<]*
```

This grammar ensures opening and closing tags match through parameter passing and guards.

### Indentation-Sensitive Languages

```dart
line(indent_level) = spaces(level: indent_level) content

spaces(level) = ' '{level}

content = [a-zA-Z]+
```

Parameters track the expected indentation level through nested parse calls.

### Parameterized Separators

```dart
list(separator, item) = item (separator item)*

csv = list(separator: ",", item: field)
tsv = list(separator: "\t", item: field)

field = [^,\t\n]+
```

The same `list` rule works with different separators by parameterization.

### Data-Driven Grammars

```dart
expression(level) = atom
                  | binop(level: level)

binop(min_level) = if (min_level <= 1)
                   left:atom '+' right:expression(level: 2)
```

Parameters control parsing flow based on runtime values (precedence levels, flags, etc.).

---

## Advanced Scenarios

### Recursive Parameters

Parameters can reference rules that call themselves through parameters:

```dart
list_of(element) = '[' (element (',' element)*)? ']'

start = list_of(element: list_of(element: digit))

digit = [0-9]
```

This matches nested lists like `[[1,2],[3,4]]`.

### Parameter Forwarding Through Sequences

When multiple rules in a sequence reference the same parameter, they all see the same value:

```dart
triple(item) = item item item

start = triple(item: letter)

letter = [a-z]
```

Matches exactly three letters.

### Ambiguity with Parameters

Parameterized rules can participate in ambiguous parses:

```dart
wrapper(content) = '(' content ')'

start = wrapper(content: ambiguous)

ambiguous = 'x' | 'x'
```

The ambiguity in `ambiguous` is preserved through the parameter.

---

## Implementation Details

### Argument Resolution

During the state machine execution, when a `ParameterRefPattern` is encountered:

1. The current call frame is retrieved from the parse context
2. The parameter name is looked up in the frame's argument map
3. If found, the argument value is retrieved; otherwise, an error occurs
4. The argument is processed based on its type (string, pattern, or rule)

### Call Stack Management

The call stack is maintained as part of the parse context (Context object in [lib/src/parser/common/context.dart](lib/src/parser/common/context.dart)):

```dart
class Context {
  final CallerKey caller;  // Reference to call stack frame
  // ... other fields
}
```

Each rule call creates a new caller node linked to the parent, forming a chain.

### Caching in ParameterCallPattern

`ParameterCallPattern` caches resolved arguments to avoid repeated computation:

```dart
({Map<String, Object?> arguments, CallArgumentsKey key}) resolveArgumentsAndKey(
  CallArgumentsKey parentKey,
) {
  // Cache lookup
  if (_cache.containsKey(parentKey)) {
    return _cache[parentKey]!;
  }

  // Resolve and cache
  // ...
}
```

This optimization is critical for grammars with heavy parameter usage.

---

## Testing

Key test files for parameters:

- [data_driven_parameters_test.dart](../test/features/data_driven_parameters_test.dart): Comprehensive parameter functionality tests
- [data_driven_rules_test.dart](../test/features/data_driven_rules_test.dart): Rule-based parameter testing
