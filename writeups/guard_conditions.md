# Guard Conditions in Glush: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Guard Types](#guard-types)
3. [Pattern-Level Representation](#pattern-level-representation)
4. [Grammar Syntax](#grammar-syntax)
5. [Compilation](#compilation)
6. [Guard Evaluation](#guard-evaluation)
7. [Guards vs Predicates](#guards-vs-predicates)
8. [Caching and Memoization](#caching-and-memoization)
9. [Guard Environment](#guard-environment)
10. [Inline Guards](#inline-guards)
11. [Branch Guards](#branch-guards)
12. [Advanced Scenarios](#advanced-scenarios)
13. [Implementation Details](#implementation-details)

---

## Core Concept

Guards in Glush are **semantic preconditions** that determine whether a rule can be entered based on runtime values. Unlike predicates, which examine the input stream syntactically, guards evaluate expressions against:

- **Position information**: current parse position, where the rule was called
- **Captured values**: results from previous parsing
- **Rule arguments**: parameters passed to the rule
- **Precedence context**: minimum and current precedence levels

### Primary Purpose

Guards serve two critical functions:

1. **Semantic Dispatch**: In alternations, route parsing to different branches based on runtime conditions rather than input lookahead. This is particularly powerful for context-dependent languages.

2. **Early Constraint Checking**: Prevent entering a rule if preconditions aren't met, causing backtracking to alternatives rather than failing deep within the rule body.

### Key Property: Non-Consuming Assessment

Like predicates, guards **do not consume input**. A guard evaluation examines runtime state but leaves the input position unchanged. If a guard fails, the parser can try alternatives without having advanced the input.

### Distinction from Input Patterns

Guards operate on the **parsing context** (metadata), not the input stream. This is fundamentally different from pattern matching. A pattern asks "what's in the input?" while a guard asks "is it valid to try this pattern now given our context?"

---

## Guard Types

### Literal Guards

**Syntax**: `true` or `false` (in guard expressions)

**Purpose**: Simple hard-coded conditions that always pass or always fail.

```dart
// Always succeeds
if_(GuardExpr.literal(true), pattern)

// Always fails
if_(GuardExpr.literal(false), pattern)
```

**Use cases**:

- Placeholder/stub implementations during development
- Conditional compilation via grammar transformations
- Disabling/enabling rules dynamically

### Value-Based Guards

**Purpose**: Compare runtime values against literals or other values.

**Available Values**:

1. **Rule Arguments**: Parameters passed when the rule is invoked

   ```dart
   GuardValue.argument("count")  // Reference parameter "count"
   GuardValue.argument("level")  // Reference parameter "level"
   ```

2. **Built-in Context Values**: Automatically available in every guard
   - `position`: Current parse position (0-based index into input)
   - `callStart`: Input position where the current rule was called
   - `precedenceLevel`: Current operator precedence level
   - `minPrecedenceLevel`: Minimum required precedence for this rule call
   - `ruleName`: Name of the currently executing rule

3. **Captured Values**: Results from explicit captures in earlier parsing
   ```dart
   GuardValue.capture("varName")  // Reference a labeled mark
   ```

**Comparison Operators**:

```dart
GuardValue.argument("x").eq(10)      // Equal to
GuardValue.argument("x").ne(0)       // Not equal to
GuardValue.argument("x").gt(5)       // Greater than
GuardValue.argument("x").gte(5)      // Greater than or equal
GuardValue.argument("x").lt(100)     // Less than
GuardValue.argument("x").lte(100)    // Less than or equal
```

**Example**:

```dart
// Only match if count argument > 0
if_(GuardValue.argument("count").gt(0), pattern)

// Only match at position 0 (start of input)
if_(GuardValue.builtin("position").eq(0), pattern)
```

### Boolean Combinators

Guards can be combined using logical operations to express complex conditions.

**AND Combinator**:

```dart
var guard1 = GuardValue.argument("x").gt(0);
var guard2 = GuardValue.argument("y").lt(10);
var combined = guard1.and(guard2);  // x > 0 AND y < 10

// Using & operator
var combinedOp = guard1 & guard2;
```

**OR Combinator**:

```dart
var guard1 = GuardValue.argument("x").eq(0);
var guard2 = GuardValue.argument("x").eq(1);
var combined = guard1.or(guard2);  // x == 0 OR x == 1

// Using | operator
var combinedOp = guard1 | guard2;
```

**NOT Combinator**:

```dart
var base = GuardValue.argument("x").eq(0);
var negated = base.not();  // NOT (x == 0), i.e., x != 0

// Using ~ operator
var negatedOp = ~base;
```

**Example of Complex Guard**:

```dart
var guard = (GuardValue.argument("x").gt(0) & GuardValue.argument("y").lt(100))
          | GuardValue.argument("skip").eq(true);
// (x > 0 AND y < 100) OR skip == true
```

---

## Pattern-Level Representation

### Core Classes

In the Glush implementation, guards are represented at the pattern level through classes in [lib/src/core/patterns.dart](lib/src/core/patterns.dart):

- **Core Guard Pattern**: [lib/src/core/patterns.dart:2611-2655](../lib/src/core/patterns.dart#L2611-L2655)
- **Rule Guarding**: [lib/src/core/patterns.dart:2690-2693](../lib/src/core/patterns.dart#L2690-L2693)

**IfCond Pattern**:

```dart
class IfCond extends Pattern {
  final GuardExpr guard;        // The guard condition
  final Pattern pattern;        // The pattern to guard

  IfCond(this.guard, this.pattern);

  // Copy constructor
  IfCond copy() => IfCond(guard, pattern.copy());

  // Guards are non-consuming (static)
  bool isStatic() => true;

  // Guards don't match epsilon
  bool get calculateEmpty => false;
}
```

**GuardExpr (Sealed Hierarchy)**:

```dart
sealed class GuardExpr {
  // Logical combinators
  GuardExpr and(GuardExpr other) { ... }
  GuardExpr or(GuardExpr other) { ... }
  GuardExpr not() { ... }

  // Evaluation
  bool evaluate(GuardEnvironment env) { ... }
}

// Concrete implementations
final class LiteralGuard extends GuardExpr {
  final bool value;
  LiteralGuard(this.value);
}

final class ExpressionGuard extends GuardExpr {
  final GuardValue value;
  final String operator;  // '==', '!=', '<', '>', '<=', '>='
  final Object? operand;
  ExpressionGuard(this.value, this.operator, this.operand);
}

final class BinaryGuard extends GuardExpr {
  final GuardExpr left;
  final String op;  // '&&', '||'
  final GuardExpr right;
  BinaryGuard(this.left, this.op, this.right);
}

final class UnaryGuard extends GuardExpr {
  final GuardExpr inner;
  UnaryGuard(this.inner);  // Negation
}
```

**GuardValue (Sealed Hierarchy)**:

```dart
sealed class GuardValue {
  // Factory constructors
  static ArgumentValue argument(String name) { ... }
  static CaptureValue capture(String name) { ... }
  static BuiltinValue builtin(String name) { ... }

  // Comparison operators
  ExpressionGuard eq(Object? value) { ... }
  ExpressionGuard ne(Object? value) { ... }
  ExpressionGuard gt(Comparable value) { ... }
  ExpressionGuard gte(Comparable value) { ... }
  ExpressionGuard lt(Comparable value) { ... }
  ExpressionGuard lte(Comparable value) { ... }
}

// Concrete implementations
final class ArgumentValue extends GuardValue {
  final String name;
  ArgumentValue(this.name);
}

final class CaptureValue extends GuardValue {
  final String name;
  CaptureValue(this.name);
}

final class BuiltinValue extends GuardValue {
  final String name;  // 'position', 'callStart', 'precedenceLevel', etc.
  BuiltinValue(this.name);
}
```

### Key Characteristics

**Non-Consuming**: Guards have `isStatic() => true`. This indicates that evaluating a guard does not consume input and does not affect the parser's position tracking.

**Transparent to Structure**: The `firstSet()` and `lastSet()` of an `IfCond` return the same sets as the wrapped pattern. Structurally, guards are "invisible"—they don't contribute symbols to first/last sets.

**Rule Integration**: Attached to `Rule` objects via the `guard` field, making guards part of rule definition rather than part of the pattern tree itself.

---

## Grammar Syntax

### Sequence-Level Guards (Branch Conditions)

**Syntax**: `if (condition) pattern_sequence`

This guard applies to the remainder of the sequence.

```
rule = if (position == 0) "start" middle end
```

This rule:

1. Checks that `position == 0` (at start of input)
2. If true, matches "start", then middle, then end
3. If false, the entire rule fails (no alternatives tried)

**Semantics**: The guard gate must open before any part of the sequence is attempted.

### Inline Guards

**Syntax**: `(if (condition) pattern)` inside parentheses

Applies the guard to a single pattern, useful in alternations.

```
rule = (if (n == 1) '') single_item
     | (if (n > 1) '') multiple_items
```

Each branch has its own guard. The parser tries branches in order:

1. Enter branch 1, evaluate guard for `n == 1`
2. If false, backtrack and try branch 2
3. Evaluate guard for `n > 1`
4. If either succeeds, proceed with that branch

**Semantics**: Guard protects one pattern; alternation continues to next branch on guard failure.

### Guard Expressions

**Simple Comparisons**:

```
if (position == 0) ...      // At start of input
if (n != 0) ...             // Argument n not zero
if (level > 10) ...         // Precedence level exceeds 10
```

**Logical AND**:

```
if (position > 0 && position < 100) ...  // Within range
if (x == 1 && y == 2) ...                // Both conditions
```

**Logical OR**:

```
if (mode == 'strict' || mode == 'lenient') ...  // Multiple modes
```

**Negation** (if supported):

```
if (!(position == 0)) ...   // Not at start
```

---

## Compilation

### Representation Chain

Guards transition through several representations during compilation:

1. **Grammar Text**: Raw syntax like `if (position == 0) "a"`
2. **Grammar AST (`IfPattern`)**: Parsed grammar representation
3. **Pattern Objects (`IfCond`)**: Pattern tree representation
4. **Synthetic Rule**: Extracted into a named rule with guard attached
5. **Runtime Evaluation**: Guard expressions and cached results

### Grammar Parsing

When the grammar parser encounters a guard in [lib/src/compiler/parser.dart](lib/src/compiler/parser.dart#L515):

```dart
PatternExpr _tryParseGuardPrefix() {
  // Check for 'if' keyword at sequence start
  if (peek().type == TokenType.if_) {
    consume();  // consume 'if'
    consume(TokenType.leftParen);

    // Recursively parse guard expression
    var guardExpr = _parseExpression();

    consume(TokenType.rightParen);

    // Parse the guarded pattern
    var pattern = _parseSequence();

    return IfPattern(pattern, guardExpr, isInline: false);
  }
}
```

**Guard Expression Parsing** ([lib/src/compiler/parser.dart](lib/src/compiler/parser.dart#L554)):

Guard expressions use recursive descent with operator precedence:

```dart
GuardExprNode _parseExpression() {
  return _parseOr();  // Lowest precedence
}

GuardExprNode _parseOr() {
  var left = _parseAnd();
  while (match(TokenType.or)) {
    var right = _parseAnd();
    left = BinaryGuardNode(left, "||", right);
  }
  return left;
}

GuardExprNode _parseAnd() {
  var left = _parseUnary();
  while (match(TokenType.and)) {
    var right = _parseUnary();
    left = BinaryGuardNode(left, "&&", right);
  }
  return left;
}

GuardExprNode _parseUnary() {
  if (match(TokenType.not)) {
    return UnaryGuardNode(_parseUnary());
  }
  return _parseComparison();
}

GuardExprNode _parseComparison() {
  var left = _parsePrimary();
  if (match(TokenType.eq, TokenType.ne, TokenType.lt, ...)) {
    var op = previous().value;
    var right = _parsePrimary();
    return ComparisonGuardNode(left, op, right);
  }
  return left;
}

GuardExprNode _parsePrimary() {
  // Handles: positions, arguments, built-in values, literals
  if (check(TokenType.identifier)) {
    return GuardValueNode(identifier);
  }
  if (check(TokenType.number)) {
    return GuardLiteralNode(number);
  }
  // ...
}
```

### Pattern Compilation

During compilation in [lib/src/compiler/compiler.dart](lib/src/compiler/compiler.dart#L81):

```dart
case IfPattern():
  // 1. Create a synthetic rule to hold the guard
  var syntheticRuleName = "_if\$${guardCounter++}";
  var syntheticRule = Rule(syntheticRuleName, () {
    // Pattern body is the inner pattern
    return expr.pattern;
  });

  // 2. Compile the guard expression from AST to runtime form
  var compiledGuard = _compileGuardExpr(expr.guard);
  syntheticRule.guard = compiledGuard;

  // 3. Add synthetic rule to grammar
  grammar.rules.add(syntheticRule);

  // 4. Return a call to the synthetic rule
  return RuleCall(syntheticRule);
```

### Guard Expression Compilation

Guard expressions are compiled to `GuardExpr` objects:

```dart
GuardExpr _compileGuardExpr(GuardExprNode node) {
  return switch (node) {
    LiteralGuardNode(:final value) => LiteralGuard(value),

    ComparisonGuardNode(:final left, :final op, :final right) =>
      ExpressionGuard(
        _compileGuardValue(left),
        op,
        _compileGuardValue(right),
      ),

    BinaryGuardNode(:final left, :final op, :final right) =>
      BinaryGuard(
        _compileGuardExpr(left),
        op,
        _compileGuardExpr(right),
      ),

    UnaryGuardNode(:final inner) =>
      UnaryGuard(_compileGuardExpr(inner)),
  };
}

GuardValue _compileGuardValue(GuardValueNode node) {
  return switch (node) {
    ArgumentValueNode(:final name) => ArgumentValue(name),
    CaptureValueNode(:final name) => CaptureValue(name),
    BuiltinValueNode(:final name) => BuiltinValue(name),
  };
}
```

### Pattern Normalization

Inline guards embedded in patterns are extracted during grammar normalization in [lib/src/core/grammar.dart](lib/src/core/grammar.dart#L254):

```dart
Pattern _normalizePattern(Pattern p) {
  if (p is IfCond) {
    // Extract guard to synthetic rule
    var syntheticRule = Rule("if\$${++counter}", () => p.pattern);
    syntheticRule.guard = p.guard;
    this.rules.add(syntheticRule);

    // Return rule call
    return RuleCall(syntheticRule);
  }
  // Recursively normalize child patterns
  return p.normalizeChildren();
}
```

---

## Guard Evaluation

### Evaluation Entry Point

Guards are evaluated in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L318):

```dart
bool _ruleGuardPasses(
  Rule rule,
  Frame frame,
  {required Map<String, Object?> arguments,
   required CallArgumentsKey argumentsKey}
) {
  var guard = rule.guard;

  // No guard = always passes
  if (guard == null) return true;

  // Check cache first (memoization)
  var cacheKey = GuardCacheKey(
    rule: rule,
    guard: guard,
    callArgumentsKey: argumentsKey,
    position: frame.position,
    callStart: frame.context.callStart,
    precedenceLevel: frame.context.precedenceLevel,
  );

  if (parseState.guardResultCache.containsKey(cacheKey)) {
    return parseState.guardResultCache[cacheKey]!;
  }

  // Build evaluation environment
  var env = GuardEnvironment(
    arguments: arguments,
    captures: frame.context.captures,
    position: frame.position,
    callStart: frame.context.callStart,
    precedenceLevel: frame.context.precedenceLevel,
    minPrecedenceLevel: frame.context.minPrecedenceLevel,
    rule: rule,
  );

  // Evaluate guard expression
  var result = guard.evaluate(env);

  // Memoize result for this cache key
  parseState.guardResultCache[cacheKey] = result;

  return result;
}
```

### When Guards Are Checked

Guards are checked at two critical points:

**1. Rule Entry** (when a rule call is about to be made):

In [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L480):

```dart
case CallAction():
  var targetRule = action.rule;

  // Check if guard passes
  if (!_ruleGuardPasses(targetRule, frame, arguments: args, ...)) {
    GlushProfiler.increment("parser.rule_calls.guard_rejected");
    return;  // Guard failed, don't enter the rule
  }

  // Guard passed, spawn rule call
  _spawnRuleCall(targetRule, frame, args);
```

**2. Alternative Backtracking** (when trying alternate rules):

If a rule call fails and backtracking occurs, the parser tries alternatives. If the alternative is guarded, its guard is checked before attempting that rule.

### Evaluation Environment

The `GuardEnvironment` provides context for evaluating guard expressions in [lib/src/core/patterns.dart](lib/src/core/patterns.dart#L1074):

```dart
class GuardEnvironment {
  final Map<String, Object?> arguments;      // Rule parameters
  final CaptureBindings captures;            // Labeled marks
  final int position;                        // Current parse position
  final int? callStart;                      // Where rule was called
  final int? precedenceLevel;                // Current precedence
  final int? minPrecedenceLevel;             // Minimum required
  final Rule rule;                           // The rule being guarded
  final Map<String, Object?> customResolvers; // Custom value lookups
}
```

The environment supports **four-stage name resolution**:

```
Looking up value "x":
1. Check rule arguments
   if (arguments.containsKey("x")) return arguments["x"]

2. Check captured values
   if (captures.get("x") != null) return captures.get("x")

3. Check built-in values
   if ("x" == "position") return position
   if ("x" == "callStart") return callStart
   if ("x" == "precedenceLevel") return precedenceLevel
   if ("x" == "minPrecedenceLevel") return minPrecedenceLevel
   if ("x" == "ruleName") return rule.name

4. Check custom resolvers
   if (customResolvers.containsKey("x")) return customResolvers["x"]

5. Not found → error
```

### Guard Expression Evaluation

Each `GuardExpr` subclass implements evaluation logic:

```dart
sealed class GuardExpr {
  bool evaluate(GuardEnvironment env);
}

final class LiteralGuard extends GuardExpr {
  final bool value;

  bool evaluate(GuardEnvironment env) => value;
}

final class ExpressionGuard extends GuardExpr {
  final GuardValue value;
  final String operator;
  final Object? operand;

  bool evaluate(GuardEnvironment env) {
    var lhs = value.resolve(env);
    var rhs = operand;

    return switch (operator) {
      "==" => lhs == rhs,
      "!=" => lhs != rhs,
      ">" => (lhs as Comparable).compareTo(rhs as Comparable) > 0,
      "<" => (lhs as Comparable).compareTo(rhs as Comparable) < 0,
      ">=" => (lhs as Comparable).compareTo(rhs as Comparable) >= 0,
      "<=" => (lhs as Comparable).compareTo(rhs as Comparable) <= 0,
      _ => throw ArgumentError("Unknown operator: $operator"),
    };
  }
}

final class BinaryGuard extends GuardExpr {
  final GuardExpr left;
  final String op;
  final GuardExpr right;

  bool evaluate(GuardEnvironment env) {
    return switch (op) {
      "&&" => left.evaluate(env) && right.evaluate(env),
      "||" => left.evaluate(env) || right.evaluate(env),
      _ => throw ArgumentError("Unknown operator: $op"),
    };
  }
}

final class UnaryGuard extends GuardExpr {
  final GuardExpr inner;

  bool evaluate(GuardEnvironment env) => !inner.evaluate(env);
}
```

---

## Guards vs Predicates

While both guards and predicates are non-consuming constraint mechanisms, they differ fundamentally in purpose and evaluation:

### Semantic Distinction

```
Predicates (Syntactic Lookahead)
├─ Question: "What pattern matches at current position?"
├─ Evaluation: Pattern matching on input
├─ Data: Input stream only
├─ Example: &'/' ensures '/' ahead without consuming
└─ Used for: Disambiguation and lookahead decisions

Guards (Semantic Preconditions)
├─ Question: "Is it valid to try this rule now?"
├─ Evaluation: Boolean expression on context
├─ Data: Position, captures, arguments, precedence
├─ Example: if (n > 0) ensures parameter is positive
└─ Used for: Context-dependent rule selection
```

### Comparison Table

| Aspect                | Predicates                                | Guards                                         |
| --------------------- | ----------------------------------------- | ---------------------------------------------- |
| **Syntax**            | `&expr`, `!expr` (lookahead operators)    | `if (condition) expr`                          |
| **Evaluation**        | Pattern matching (syntactic)              | Expression evaluation (semantic)               |
| **Input consumption** | No (lookahead)                            | No                                             |
| **Available data**    | Parse structure, input tokens             | Position, captures, rule args, precedence      |
| **Evaluation scope**  | Entire pattern tree                       | Single rule entry                              |
| **When checked**      | Before pattern matching (lookahead phase) | At rule entry (before body execution)          |
| **Failure behavior**  | Predicate fails → path eliminated         | Guard fails → path eliminated                  |
| **Result caching**    | `PredicateKey(pattern, position)`         | `GuardCacheKey(rule, args, position, context)` |
| **Performance**       | Spawns sub-parse                          | Direct expression evaluation                   |
| **Complexity**        | Pattern graph traversal                   | Expression tree evaluation                     |

### When to Use Each

**Use Predicates When**:

- You need to look ahead at what's in the input
- Making a choice based on upcoming tokens
- You want to ensure/exclude a pattern without committing

**Use Guards When**:

- You need to check rule parameters or captured values
- Making decisions based on parse context (position, captures)
- You want semantic filtering of rule alternatives
- You need position-based parsing decisions

**Example: Combining Both**:

```dart
// Guard filters by context (parameter n)
// Then predicate filters by input pattern
var rule = Rule("item", (n) {
  return if_(
    GuardValue.argument("n").gt(0),  // Guard: n must be positive
    Token.char("a").and()             // Predicate: lookahead for 'a'
      >> Token.char("a")              // Pattern: consume 'a'
  );
});
```

---

## Caching and Memoization

### Cache Structure

Guards use intelligent caching to avoid redundant evaluation, implemented via `GuardCacheKey` in [lib/src/parser/key/guard_cache_key.dart](lib/src/parser/key/guard_cache_key.dart):

```dart
final class GuardCacheKey {
  final Rule rule;                      // The guarded rule
  final GuardExpr guard;                // The guard expression
  final CallArgumentsKey callArgumentsKey;  // Argument signature
  final int position;                   // Parse position
  final int? callStart;                 // Where rule was called
  final int? precedenceLevel;           // Current precedence level

  // Cache is indexed by all these fields
  @override
  bool operator ==(Object other) => /* compare all fields */;

  @override
  int get hashCode => /* hash all fields */;
}
```

### Memoization Benefits

The cache stores boolean results: `Map<GuardCacheKey, bool> guardResultCache`

Benefits:

1. **Same Guard, Same Context**: If the same guard is evaluated at the same position with the same arguments, the cached result is reused
2. **Reduced Expression Evaluation**: Expensive guard comparisons are only computed once per unique context
3. **Prevents Redundant Value Lookups**: Argument and capture resolution is computed once

### Cache Invalidation

Caches are **position-scoped**. When the parser moves to a new input position via `processToken()`, the guard cache is cleared because:

- Captures may shift
- Precedence context may change
- Position value changes

```dart
// At start of each processToken() call
parseState.guardResultCache.clear();
```

---

## Guard Environment

### Name Resolution Stages

The `GuardEnvironment` provides multi-stage name resolution in [lib/src/core/patterns.dart](lib/src/core/patterns.dart#L1097):
**Stage 1: Arguments**

```dart
Object? resolve(String name) {
  // First, check rule parameters
  if (arguments.containsKey(name)) {
    return arguments[name];
  }
  // ...stages 2-4...
}
```

**Stage 2: Captures**

```dart
Object? resolveCapture(String name) {
  // Values marked with label:name in earlier parsing
  return captures.get(name)?);
}
```

**Stage 3: Built-in Values**

```dart
Object? resolveBuiltin(String name) {
  return switch (name) {
    "position" => position,
    "callStart" => callStart,
    "precedenceLevel" => precedenceLevel,
    "minPrecedenceLevel" => minPrecedenceLevel,
    "ruleName" => rule.name,
    _ => null,
  };
}
```

### Available Built-in Values

- **`position`** (int): Zero-based index of the current parse position
- **`callStart`** (int?): Position where the current rule was invoked
- **`precedenceLevel`** (int?): Current operator precedence level
- **`minPrecedenceLevel`** (int?): Minimum required precedence for this rule
- **`ruleName`** (String): Name of the guarded rule
- **`rule`** (Rule): The Rule object itself

---

## Inline Guards

Inline guards are contextual guards within parentheses, useful for alternation dispatch.

### Syntax

```
( if (condition) pattern )
```

The guard is scoped to just the pattern inside parentheses.

### Compilation

Inline guards in alternations are extracted to synthetic rules during normalization:

```dart
// Grammar
rule = (if (n == 1) '') "a"
     | (if (n != 1) '') "b"

// Becomes (conceptually)
rule = _if$1() | _if$2()

_if$1() :: if (n == 1) => "a"
_if$2() :: if (n != 1) => "b"
```

Each synthetic rule has its own guard.

### Semantics

When parsing with inline guards in an alternation:

1. Attempt first alternative:
   - Enter `_if$1` (synthetic rule)
   - Evaluate guard `n == 1`
   - If true, match "a"
   - If false, backtrack

2. If first fails, try second alternative:
   - Enter `_if$2` (synthetic rule)
   - Evaluate guard `n != 1`
   - If true, match "b"
   - If false, backtrack

3. If all alternatives fail, rule fails

### Benefits of Inline Guards

- **Clear intent**: Guard is visually adjacent to its pattern
- **Cleaner alternations**: Each branch self-documents its precondition
- **Independent guards**: Each branch has its own guard context
- **Easier refactoring**: Guards don't affect siblings

---

## Branch Guards

Branch guards (sequence-level guards) apply to the remainder of a sequence.

### Syntax

```
if (condition) pattern1 pattern2 pattern3
```

The guard gates the entire sequence starting from its position.

### Semantics

If the guard at the sequence start evaluates to false:

- The entire sequence fails (no partial matching)
- The parser is not advanced
- Backtracking to alternatives occurs

### Benefits of Branch Guards

- **Atomic conditions**: Gate entire rule bodies with one check
- **Early exit**: Fail fast if preconditions aren't met
- **Sequence integrity**: Ensures all-or-nothing semantics

---

## Advanced Scenarios

### Capturing with Guards

Guards can reference captured values from earlier parsing:

```dart
var rule = Rule("bounded", () {
  return Token.char('(')
      >> capture("items", item >> (Token.char(',') >> item)*)
      >> if_(GuardValue.capture("items").gt(10), success())
      >> Token.char(')');
});

// Rule only succeeds if captured "items" > 10
```

### Parameterized Rules with Guards

Guards commonly filter rule parameters:

```dart
var itemList = Rule("itemList", (maxCount) {
  return if_(
    GuardValue.argument("maxCount").gte(1),
    item >> (Token.char(',') >> item).repeat(0, maxCount - 1)
  );
});

parser.parse(itemList(5), input);  // Guard: 5 >= 1 passes
parser.parse(itemList(0), input);  // Guard: 0 >= 1 fails
```

### Position-Based Parsing

Guards enable different behavior at different positions:

```
start = (if (position == 0) '') initial_token continuation
      | (if (position > 0) '') recovery_token continuation
```

Useful for resumable parsing or error recovery.

### Precedence-Aware Parsing

Operator precedence can be enforced via guards:

```dart
var expr = Rule("expr", (minPrec) {
  return if_(
    GuardValue.builtin("precedenceLevel").gte(minPrec),
    operand >> (operator >> operand)*
  );
});
```

### Guard Composition

Complex logic can be expressed via boolean combinations:

```dart
var rule = Rule("complexRule", (x, y, z) {
  var g1 = GuardValue.argument("x").gt(0);
  var g2 = GuardValue.argument("y").lt(100);
  var g3 = GuardValue.argument("z").ne("blocked");

  var combined = (g1 & g2) | g3;

  return if_(combined, pattern);
});
```

---

## Implementation Details

### Frame-Level Integration

Guards are checked when frames trigger rule calls in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart):

```dart
void _processAction(Frame frame, StateAction action) {
  if (action is CallAction) {
    // Before spawning rule call, check guard
    if (!_ruleGuardPasses(action.rule, frame, ...)) {
      return;  // Guard failed, don't process
    }
    _spawnRuleCall(action.rule, frame, arguments);
  }
}
```

### Performance Characteristics

| Operation           | Time        | Comments                                    |
| ------------------- | ----------- | ------------------------------------------- |
| Guard evaluation    | O(1) - O(d) | d = depth of expression tree                |
| Cache lookup        | O(1) avg    | Hash table lookup                           |
| Argument resolution | O(1) avg    | Map lookup in arguments                     |
| Capture resolution  | O(n)        | Linear search in captures (typically small) |

### Profiling Hooks

Guard evaluation is instrumented. In production parsing, count:

- `parser.rule_calls.guard_rejected`: Rules whose guards failed
- `parser.guard_cache.hits`: Cache hits
- `parser.guard_cache.misses`: Cache misses

---

## Test Files and Usage Examples

### Main Test Files

| File                                                                                         | Focus                                                                  |
| -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| [test/features/inline_guard_test.dart](test/features/inline_guard_test.dart)                 | Guards API, normalization, SMParser integration, position-based guards |
| [test/features/grammarfile_if_guard_test.dart](test/features/grammarfile_if_guard_test.dart) | Grammar syntax, compilation, recognition, captures, recursion          |

### Example 1: Simple Literal Guard

```dart
var grammar = Grammar(() {
  return Rule("test", () {
    return if_(
      GuardExpr.literal(true),
      Token.char('a')
    );
  });
});

var parser = SMParser(grammar);
expect(parser.recognize("a"), isTrue);   // Guard always true
expect(parser.recognize("b"), isFalse);  // Pattern fails
```

### Example 2: Position Guard

```dart
var grammar = Grammar(() {
  return Rule("start", () {
    return if_(
      GuardValue.builtin("position").eq(0),
      Token.char('a')
    );
  });
});

var parser = SMParser(grammar);
expect(parser.recognize("a"), isTrue);   // position==0 initially
```

### Example 3: Parameterized Guard

```dart
var grammar = Grammar(() {
  return Rule("positive", (n) {
    return if_(
      GuardValue.argument("n").gt(0),
      Token.char('x')
    );
  });
});

var rule = grammar.rules.first;
expect(rule.invoke(1, "x"), isTrue);   // n=1 > 0, passes
expect(rule.invoke(0, "x"), isFalse);  // n=0 > 0 fails, guard blocks
```

### Example 4: Alternation with Guards

```
expr = (if (precedence <= 0) '') primary
     | (if (precedence <= 5) '') additive
     | (if (precedence <= 10) '') multiplicative
```

Each alternative has its own precedence guard for operator dispatch.

---

## Conclusion

Guard conditions in Glush provide a powerful mechanism for:

1. **Semantic Filtering**: Route parsing based on context rather than just input patterns
2. **Efficient Dispatch**: Avoid exploring impossible branches early
3. **Captured Checks**: Enforce constraints on earlier parsing results
4. **Parameterized Parsing**: Make rule behavior context-dependent
5. **Precedence Management**: Implement operator precedence via guards

Combined with predicates (syntactic lookahead), guards form a complete constraint-checking system that enables sophisticated parsing without excessive lookahead or complex state management.

The architecture cleanly separates guard compilation from evaluation, guarding from patterns, and provides intelligent caching to ensure that redundant evaluations never occur within a single parse of a token position.
