# Predicates in Glush: A Detailed Technical Writeup

## Table of Contents

1. [Core Concept](#core-concept)
2. [Predicate Types](#predicate-types)
3. [Pattern-Level Representation](#pattern-level-representation)
4. [Grammar Compilation](#grammar-compilation)
5. [State Machine Integration](#state-machine-integration)
6. [Runtime Execution](#runtime-execution)
7. [Predicate Lifecycle](#predicate-lifecycle)
8. [Memoization and Tracking](#memoization-and-tracking)
9. [Context and Nesting](#context-and-nesting)
10. [Parameter Predicates](#parameter-predicates)
11. [Advanced Scenarios](#advanced-scenarios)
12. [Implementation Details](#implementation-details)

---

## Core Concept

Predicates in Glush are **zero-width lookahead assertions** that examine input at the current position without consuming any characters. This is a fundamental feature of Parsing Expression Grammars (PEGs) that allows grammars to make decisions based on what comes next in the input stream without committing to consuming those characters.

The key property of predicates is that they **do not affect the input position**. When a predicate is evaluated, the parser checks a pattern at the current position, but regardless of success or failure, the input position remains unchanged. This allows the main parsing to proceed (or fail) based on what the predicate found, without the predicate itself advancing through the input.

### Primary Purpose

Predicates serve two critical functions:

1. **Constraint Checking**: Enable grammars to apply constraints before committing to a parse branch. This is essential in ambiguous grammars where multiple rules could match at the same position, but semantic or syntactic constraints need to disambiguate.

2. **Non-Backtracking Lookahead**: In PEGs, once a choice is made, backtracking is not permitted. Predicates provide a way to look ahead and make informed decisions before committing to a particular parse branch.

### Distinction from Consumption

This is critical: predicates are **not part of the language structure**. When you write a grammar rule with predicates, the predicates themselves are "transparent" to the language. They only influence which branches of the grammar are taken, but they don't contribute to which characters are consumed.

Example:

```
rule = &'a' 'a'
```

This rule has two parts:

- The predicate `&'a'` checks if 'a' is at the current position (doesn't consume)
- The `'a'` consumes the 'a'

If the input is "a", the predicate succeeds, and then we consume 'a'. If the input is "b", the predicate fails and the entire rule fails without consuming anything.

---

## Predicate Types

### Positive Lookahead (AND Predicate)

**Syntax**: `&pattern`

**Semantics**: The predicate succeeds if the given pattern matches at the current input position. The pattern is evaluated without consuming input.

**Formal Definition**:

- Let $pos$ be the current input position
- Let $pattern$ be the pattern to check
- The AND predicate succeeds if $pattern$ matches starting at position $pos$
- The input position remains at $pos$ regardless of match outcome
- The main parse continues at position $pos$

**Behavior**:

1. Save current input position
2. Spawn sub-parse to evaluate the pattern
3. If sub-parse succeeds, the predicate succeeds (continue from saved position)
4. If sub-parse fails, the predicate fails (continue from saved position, but rule may backtrack)
5. Control returns to the saved position regardless

**Example**:

```dart
var a = Token.char('a');
var rule = Rule("test", () => a.and() >> a);

// Input: "a"
// Position 0: AND predicate checks if 'a' exists at 0 → succeeds
// Position 0: Consume 'a' → succeeds, consumed position = 1
// Result: Match!

// Input: "b"
// Position 0: AND predicate checks if 'a' exists at 0 → fails
// Rule fails immediately
```

The AND predicate is useful when you need to confirm what's ahead before proceeding. This is particularly valuable in grammars where multiple rules could start with the same token, but you need to look further ahead to determine which rule to follow.

### Negative Lookahead (NOT Predicate)

**Syntax**: `!pattern`

**Semantics**: The predicate succeeds if the given pattern does NOT match at the current input position. It is the logical negation of a positive lookahead.

**Formal Definition**:

- Let $pos$ be the current input position
- Let $pattern$ be the pattern to check
- The NOT predicate succeeds if $pattern$ fails to match starting at position $pos$
- The input position remains at $pos$ regardless
- The main parse continues at position $pos$ if the predicate succeeds

**Behavior**:

1. Save current input position
2. Spawn sub-parse to evaluate the pattern
3. If sub-parse fails, the predicate succeeds (continue from saved position)
4. If sub-parse succeeds, the predicate fails (rule backtracking/failure)
5. Control returns to the saved position regardless

**Example**:

```dart
var a = Token.char('a');
var x = Token.char('x');
var rule = Rule("test", () => x.not() >> a);

// Input: "a"
// Position 0: NOT predicate checks if 'x' exists at 0 → no match, predicate succeeds
// Position 0: Consume 'a' → succeeds
// Result: Match!

// Input: "xa"
// Position 0: NOT predicate checks if 'x' exists at 0 → matches, predicate fails
// Rule fails immediately
```

The NOT predicate is used to enforce negative constraints. For example, a keyword checker might use: `!keyword >> identifier`, meaning "match an identifier if it's not a keyword".

### The Inversion Relationship

AND and NOT are logical inverses:

- `!(pattern)` is equivalent to `not(and(pattern))`
- `&(pattern)` is equivalent to `not(not(pattern))`

In the implementation, the `And` class has a method `invert()` that returns `Not(pattern)`, and vice versa. This relationship is used during grammar optimization and manipulation.

---

## Pattern-Level Representation

### Core Classes

In the Glush implementation, predicates are represented at the pattern level through two classes in [lib/src/core/patterns.dart](lib/src/core/patterns.dart#L2853-L2947):

```dart
class And extends Pattern {
  final Pattern pattern;

  And(this.pattern);

  // Copy constructor for creating independent instances
  And copy() => And(pattern.copy());

  // Logical inversion: AND becomes NOT
  Not invert() => Not(pattern);

  // AND predicates are never empty (they're zero-width, not consuming)
  bool get calculateEmpty => false;

  // AND predicates are always static (non-consuming)
  bool isStatic() => true;
}

class Not extends Pattern {
  final Pattern pattern;

  Not(this.pattern);

  // Copy constructor
  Not copy() => Not(pattern.copy());

  // Logical inversion: NOT becomes AND
  And invert() => And(pattern);

  // NOT predicates are never empty
  bool get calculateEmpty => false;

  // NOT predicates are always static
  bool isStatic() => true;
}
```

### Key Characteristics

**Static Property**: Both `And` and `Not` have `isStatic() => true`. This signals to the parser that these patterns do not consume input. This is critical for the parser's internal tracking—when it encounters a static pattern, it knows not to advance the input position.

**Empty Set Behavior**: The `calculateEmpty` property always returns `false`. This might seem counterintuitive since predicates don't consume input, but in Glush's terminology, "empty" refers to whether a pattern can successfully match the epsilon (empty string). Predicates themselves don't match the epsilon—they match based on lookahead.

**Inversion**: The `invert()` method enables logical transformations. When the compiler sees an inverted predicate, it can flip between AND and NOT. This is used during grammar transformations and optimizations.

**First/Last Sets**: Predicates contribute `{this}` to both the first set and last set of any sequence they appear in. This signals that the predicate itself is the "boundary" of that sequence for lookahead purposes.

**No Pair Contribution**: The `eachPair()` method returns an empty set for predicates. Predicates do not directly participate in first-set disambiguation within sequences because they don't consume tokens.

### DSL Methods

For convenient grammar construction, the `Pattern` base class provides extension methods:

```dart
// Create AND predicate wrapping this pattern
And and() => And(this);

// Create NOT predicate wrapping this pattern
Not not() => Not(this);

// Usage example
var pattern = Token.char('a');
var rule = Rule("lookAhead", () => pattern.and() >> pattern);  // a.and() >> a
var negRule = Rule("negate", () => pattern.not() >> Token.char('b'));  // a.not() >> b
```

---

## Grammar Compilation

### Grammar-Level Representation

Before patterns are compiled into the state machine, they exist as grammar expressions. The grammar parser represents predicates using the `PredicatePattern` class in [lib/src/compiler/format.dart](lib/src/compiler/format.dart):

```dart
class PredicatePattern implements PatternExpr {
  final bool isAnd;          // true for &, false for !
  final PatternExpr pattern; // The inner pattern

  PredicatePattern(this.pattern, {required this.isAnd});

  String toString() {
    final prefix = isAnd ? '&' : '!';
    return '$prefix$pattern';
  }
}
```

### Grammar Parsing

When the grammar parser encounters a predicate in the grammar source, it uses the following logic in [lib/src/compiler/parser.dart](lib/src/compiler/parser.dart#L863):

```dart
PatternExpr _parsePrefix() {
  // Check for & or ! at the start of a prefix expression
  if (type == _TokenType.ampersand) {
    // Parse the inner pattern
    var inner = _parsePrimary();
    return PredicatePattern(inner, isAnd: true);
  }
  if (type == _TokenType.bang) {
    // Parse the inner pattern
    var inner = _parsePrimary();
    return PredicatePattern(inner, isAnd: false);
  }
  // ... handle other cases
}
```

**Grammar Syntax**:

```
predicate_expr = ('&' | '!') primary_expr
primary_expr = '(' pattern ')' | rule_name | token | ...
```

Examples of valid grammar:

```
rule1 = &'a' >> 'b'                    // AND followed by sequence
rule2 = !('if' | 'while') >> identifier // NOT with complex pattern
rule3 = &rule_name >> sequence         // AND with rule reference
```

### Compilation Phase

During compilation in [lib/src/compiler/compiler.dart](lib/src/compiler/compiler.dart#L291), the grammar representation is converted to pattern objects:

```dart
case PredicatePattern():
  // Recursively compile the inner pattern
  var inner = _compilePattern(expr.pattern, precedenceLevels);

  // Wrap in And or Not based on the flag
  if (expr.isAnd) {
    return And(inner);
  } else {
    return Not(inner);
  }
```

**Compilation Process**:

1. The compiler traverses the grammar AST
2. For each `PredicatePattern`, it recursively compiles the inner pattern
3. It wraps the compiled inner pattern in either `And` or `Not`
4. The resulting `And` or `Not` object is inserted into the pattern tree

This means predicates can nest: `Token.char('a').and().and()` → `And(And(Token.char('a')))`, and the compiler handles this recursively.

---

## State Machine Integration

### State Machine Actions

The state machine is a compiled representation of the grammar that drives parser execution. Predicates manifest in the state machine as actions within states. The relevant classes are in [lib/src/parser/state_machine/state_actions.dart](lib/src/parser/state_machine/state_actions.dart#L311-L329):

```dart
final class PredicateAction implements StateAction {
  final bool isAnd;           // true = AND (&), false = NOT (!)
  final PatternSymbol symbol; // The predicate pattern to check
  final State nextState;      // State to transition to on success

  PredicateAction(this.symbol, this.nextState, {required this.isAnd});
}

final class ParameterPredicateAction implements StateAction {
  final bool isAnd;        // true = AND, false = NOT
  final String name;       // Parameter name being checked
  final State nextState;   // State to transition to on success

  ParameterPredicateAction(this.name, this.nextState, {required this.isAnd});
}
```

### State Transitions

When the state machine is built from the pattern tree, predicates result in specific state transitions:

**For a sequence like `&pattern >> nextThing`**:

- State 1: Contains `PredicateAction` for the `&pattern` lookahead
  - If predicate succeeds → transition to State 2
  - If predicate fails → no transition (rule fails)
- State 2: Processes `nextThing`

**For a negative lookahead like `!pattern >> nextThing`**:

- State 1: Contains `PredicateAction` for the `!pattern` lookahead
  - If predicate succeeds (pattern fails) → transition to State 2
  - If predicate fails (pattern succeeds) → no transition

The state machine doesn't "know" about the semantics of the predicate. It only knows there's a `PredicateAction` that needs to be evaluated at runtime. The actual evaluation of the predicate happens in the parser's step processing.

### Symbol Table

States refer to predicates using `PatternSymbol` objects, which are unique identifiers for patterns. These symbols are created during the state machine compilation process. The `PatternSymbol` typically includes:

- A unique ID
- A reference to the pattern object

This allows the state machine to refer to patterns without storing the full pattern tree in every state.

---

## Runtime Execution

### Overview of Parsing

Glush's parser processes input character by character, maintaining a set of "active frames" at each position. A frame represents an active parsing thread at a particular state and input position. When a frame encounters a `PredicateAction`, the parser must evaluate the predicate.

### Predicate Sub-Parse Spawning

When the parser encounters a `PredicateAction` at runtime, it spawns a **sub-parse** to evaluate the predicate. This is implemented in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L178):

```dart
void _spawnPredicateSubparse(PatternSymbol symbol, Frame frame) {
  // 1. Look up the entry state for the predicate pattern in the state machine
  var entryState = parseState.parser.stateMachine.ruleFirst[symbol];

  // 2. Create a unique caller key for this predicate invocation
  //    Key = (pattern_id, input_position)
  var predicateKey = PredicateCallerKey(symbol, position);

  // 3. Add this key to the predicate stack in the context
  //    (for tracking nested predicates)
  var nextStack = frame.context.predicateStack.add(predicateKey);

  // 4. Enqueue the sub-parse with a new frame at the entry state
  _enqueue(
    entryState,           // State to start in
    Context(              // Parsing context
      predicateKey,       // This is a predicate sub-parse
      arguments: frame.context.arguments,        // Inherit parent's arguments
      captures: frame.context.captures,          // Inherit parent's captures
      predicateStack: nextStack,                 // Add to stack
      callStart: position,                       // Mark where sub-parse started
      position: position,                        // Predicate starts at same position
    ),
    const GlushList<Mark>.empty(),  // No marks yet
  );
}
```

**Key Points**:

1. **Entry State**: The entry state for the predicate pattern is looked up in the state machine's rule table. This is the starting state for evaluating the predicate.

2. **Caller Key**: A unique key is created for this specific predicate invocation. The key is `(pattern_id, input_position)`. This key is used for memoization—if the same predicate is encountered at the same position later, the cached result is used instead of re-parsing.

3. **Predicate Stack**: The predicate caller key is added to a stack maintained in the parsing context. This stack tracks which predicates are currently active, allowing the parser to detect nested predicates and handle them correctly.

4. **Same Position**: Crucially, the sub-parse starts at the same input position (`position: position`) as the main parse. Predicates always check at the current position without advancing.

5. **Inherited Context**: The sub-parse inherits the arguments and captures from the parent parsing context. This allows predicates to reference outer scope values, which is important for semantic predicates.

### Predicate Tracking

Every predicate invocation has an associated `PredicateTracker` object in [lib/src/parser/common/trackers.dart](lib/src/parser/common/trackers.dart):

```dart
class PredicateTracker {
  final PatternSymbol symbol;           // The predicate pattern
  final int startPosition;              // Input position where it started
  final bool isAnd;                     // AND vs NOT marker

  int activeFrames = 0;                 // Count of live frames in sub-parse
  bool matched = false;                 // Whether predicate succeeded
  bool exhausted = false;               // Whether search is exhausted
  int? longestMatch;                    // End position of best match
  List<Waiter> waiters = [];

  /// True when the predicate can no longer succeed and has not matched.
  bool get canResolveFalse => !matched && !exhausted && activeFrames == 0;
}
```

**Tracking Variables**:

- `activeFrames`: Counts how many parsing frames are still active in the predicate sub-parse. When this reaches zero and all positions have been explored, the predicate result is final.

- `matched`: A boolean indicating whether the predicate succeeded at least once. For AND predicates, this means the pattern matched. For NOT predicates, this is set differently (based on whether the pattern failed).

- `exhausted`: A flag indicating whether the search space for this predicate has been fully explored. Once exhausted and all frames are done, the result won't change.

- `longestMatch`: For some predicate types, the parser tracks the longest match found during the sub-parse. This is used for NOT predicates to determine success (if nothing matched, NOT succeeds).

- `waiters`: A list of continuations (frames and context) that are waiting for this predicate to complete. When the predicate finishes, all waiters are resumed.

### Predicate Action Processing

When a frame encounters a `PredicateAction`, the parser executes logic in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L701):

```dart
case PredicateAction():
  var isAnd = action.isAnd;
  var symbol = action.symbol;

  // Look up the tracker for this predicate
  var predicateKey = PredicateKey(symbol, position);
  var tracker = parseState.predicateTrackers.get(predicateKey);

  if (tracker == null) {
    // First time encountering this predicate at this position
    // Create new tracker and spawn sub-parse
    tracker = PredicateTracker(symbol, position, isAnd);
    parseState.predicateTrackers[predicateKey] = tracker;
    _spawnPredicateSubparse(symbol, frame);

    // Park this frame as a waiter
    tracker.waiters.add((frame, action.nextState, frame.marks));

  } else if (tracker.matched) {
    // Predicate already succeeded - continue to next state
    requeue(Frame(frame.context, frame.marks)
      ..nextStates.add(action.nextState));

  } else if (tracker.canResolveFalse) {
    // Predicate has conclusively failed - don't continue
    // (frame dies here)

  } else {
    // Predicate still pending - park frame as waiter
    tracker.waiters.add((frame, action.nextState, frame.marks));
  }
```

**Execution Paths**:

1. **New Predicate**: If this is the first encounter with this predicate at this position, a tracker is created and the sub-parse is spawned. The current frame is added to the waiters list.

2. **Already Matched**: If the tracker already exists and the predicate succeeded, the frame is immediately requeued to transition to the next state.

3. **Already Failed**: If the tracker exists and the predicate has conclusively failed, the frame is not requeued (effectively killing the thread).

4. **Still Pending**: If the tracker exists but the result is still unknown, the frame is added to the waiters list and execution continues at the next position.

### Continuation Resumption

When a predicate finally resolves (meaning all sub-parse branches have finished), the parser resumes all waiting frames using the logic in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L157):

```dart
void _resumeLaggedPredicateContinuation({
  required ParseNodeKey? source,
  required Context parentContext,
  required GlushList<Mark> parentMarks,
  required State nextState,
  required bool isAnd,
  required PatternSymbol symbol,
}) {
  // Record the predicate completion in traces (for debugging)
  parseState.tracer.onMessage("Predicate matched: $symbol (AND: $isAnd)");

  // Resume main parse from the parked state
  requeue(Frame(parentContext, parentMarks)
    ..nextStates.add(nextState));
}
```

This resumes from the exact state where the frame was waiting, with the same context and marks, allowing the parse to continue as if no predicate was encountered (which is correct, since predicates are zero-width).

---

## Predicate Lifecycle

### Phase 1: Initialization

When a frame first encounters a `PredicateAction` during parsing:

1. Parser checks if a tracker already exists for this `(pattern, position)` pair
2. If not, a new `PredicateTracker` is created
3. A sub-parse is spawned at the same position
4. The current frame is added to the tracker's `waiters` list

### Phase 2: Sub-Parse Execution

The sub-parse runs like any normal parse, but with important differences:

1. **Context Marker**: The context has a `predicateStack` that indicates this is a predicate sub-parse
2. **Position Tracking**: The sub-parse maintains its own position counter, advancing through the input to try matching the predicate pattern
3. **Frame Queueing**: All frames in the sub-parse are executed at each position
4. **Active Frame Counting**: When frames are requeued from a predicate context, the tracker's `activeFrames` counter is incremented

### Phase 3: Result Determination

As the sub-parse executes:

- For **AND predicates**: If any parsing thread reaches an accepting state, `matched` is set to `true`
- For **NOT predicates**: The logic is inverted—if no thread reaches an accepting state, the predicate succeeds

### Phase 4: Completion Detection

The parser detects when a predicate has concluded via:

1. **All Frames Exhausted**: When `activeFrames` reaches zero, no more frames are active in the sub-parse
2. **Position Advancement Complete**: When all positions up to the maximum reached have been processed
3. **Exhaustion Flag**: When `exhausted` is set to `true`, indicating no new frames are being generated

### Phase 5: Resumption

Once a predicate is conclusively decided:

1. All waiting frames in the `waiters` list are resumed at the same input position
2. If predicate succeeded (AND matched OR NOT didn't match): frames transition to `action.nextState`
3. If predicate failed: frames are not resumed (they die)
4. The parse continues normally from this point

---

## Memoization and Tracking

### Predicate Memoization Strategy

Glush uses a memoization technique for predicates based on the tuple `(pattern_id, input_position)`. This is implemented through the `PredicateKey` and `PredicateCallerKey` classes in [lib/src/parser/key/caller_key.dart](lib/src/parser/key/caller_key.dart):

```dart
final class PredicateKey {
  final int patternId;
  final int startPosition;

  PredicateKey(this.patternId, this.startPosition);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PredicateKey &&
          runtimeType == other.runtimeType &&
          patternId == other.patternId &&
          startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(patternId, startPosition);
}

final class PredicateCallerKey extends CallerKey {
  final PatternSymbol pattern;
  final int startPosition;
  final int uid;  // Unique ID for this specific invocation

  PredicateCallerKey(this.pattern, this.startPosition, {required this.uid});
}
```

### Why Memoization Matters

In ambiguous grammars, the same predicate might be evaluated multiple times within a single parse:

```dart
var pattern = Pattern.char('a').and();
var rule1 = Rule("first", () => pattern >> Pattern.char('b'));
var rule2 = Rule("second", () => pattern >> Pattern.char('c'));

// If both rule1 and rule2 could match at position 0,
// the predicate is evaluated for rule1, then for rule2
// But if both are at the same position, the result is the same!
```

Memoization ensures that once a predicate is evaluated at a given position for a given pattern, the result is reused for all subsequent checks of that same predicate at that position. This is a significant performance optimization.

### Tracker Management

The parse state maintains a map of trackers:

```dart
Map<PredicateKey, PredicateTracker> predicateTrackers = {};
```

This map is indexed by the `(pattern_id, position)` pair. For each unique predicate invocation, there's exactly one tracker. All frames that encounter this predicate (whether through different rule paths or ambiguity) share the same tracker.

### Deduplication at Frame Level

Tracking is further coordinated at the frame level. When frames are about to be enqueued, the parser checks their identities. If multiple frames would be in the same state with the same context (including the same `predicateStack`), they are unified into a single frame. This prevents redundant execution of the same parsing work.

---

## Context and Nesting

### Predicate Stack

Predicates can be nested, meaning a predicate can contain another predicate in its pattern. The parser tracks this nesting using a `predicateStack` field in the `Context` class:

```dart
class Context {
  final CallerKey caller;
  final Map<String, Object?> arguments;
  final CaptureBindings captures;
  final GlushList<PredicateCallerKey> predicateStack;  // Tracks nesting!
  final int? callStart;
  final int? position;
  // ...
}
```

### How Nesting Works

When a frame is in a predicate sub-parse and encounters another predicate:

1. The new predicate's caller key is added to the `predicateStack`:

   ```dart
   var nextStack = frame.context.predicateStack.add(newPredicateKey);
   ```

2. The new sub-parse is spawned with the extended stack

3. When frames are requeued or deduced, their predicate stacks are compared. Frames with different stacks are kept separate (even if they're at the same position with the same rule).

### Nested Example

```dart
var expr = Rule("expr", () => Token.char('a') | Token.char('b'));
var predicate = expr.and();
var nested = predicate.and() >> Token.char('c');  // expr.and().and() >> c

// When evaluating expr.and() at position 0:
// - Outer predicate stack: [predicate.and()]
// - Spawns sub-parse to evaluate the inner expr.and()
// - Inner predicate stack: [predicate.and(), expr.and()]
// - Spawns sub-parse to evaluate Token.char('a') | Token.char('b')
// - Inner-inner stack would extend further if nested more
```

### Context Inheritance

When a sub-parse is spawned for a predicate, the child context inherits certain fields from the parent:

```dart
_enqueue(
  entryState,
  Context(
    predicateKey,
    arguments: frame.context.arguments,        // INHERITED
    captures: frame.context.captures,          // INHERITED
    predicateStack: nextStack,                 // EXTENDED
    callStart: position,
    position: position,
  ),
  const GlushList<Mark>.empty(),
);
```

- **Arguments**: Function/rule parameters pass through—a predicate can reference outer scope values
- **Captures**: Labeled marks from outer context are visible (though new captures are local to the predicate)
- **Predicate Stack**: Extended with the new predicate key

This inheritance allows semantic predicates to access function parameters and enables complex constraint logic.

---

## Parameter Predicates

### Purpose and Definition

While pattern predicates operate on lookahead patterns, **parameter predicates** operate on semantic values. They check constraints on function parameters or captured values at parse time.

Parameter predicates use the same `&` and `!` syntax but are distinguished by their target:

- Pattern predicates: `&pattern`, `!pattern` → Check if pattern matches
- Parameter predicates: `&parameter_expr`, `!parameter_expr` → Check if parameter expression matches

### Implementation

Parameter predicates are implemented in [lib/src/parser/common/step.dart](lib/src/parser/common/step.dart#L565):

```dart
void _spawnParameterPredicateSubparse(
  String parameterName,
  bool isAnd,
  Frame frame,
) {
  // Create a synthetic parameter check state machine entry
  var entryState = parseState.parser.stateMachine
      .parameterPredicateEntry(parameterName, isAnd);

  // Create a caller key for this parameter predicate
  var predicateKey = PredicateCallerKey(
    PatternSymbol(parameterName),
    position,
    uid: _getUniqueId(),
  );

  // Spawn sub-parse
  _enqueue(
    entryState,
    Context(
      predicateKey,
      arguments: frame.context.arguments,
      captures: frame.context.captures,
      predicateStack: frame.context.predicateStack.add(predicateKey),
      callStart: position,
      position: position,
    ),
    const GlushList<Mark>.empty(),
  );
}
```

### Execution Model

Parameter predicates work similarly to pattern predicates:

1. When encountered, a sub-parse is spawned
2. The sub-parse evaluates a check on the parameter value
3. For AND: succeeds if the parameter value is in an accepting state
4. For NOT: succeeds if the parameter value is not in an accepting state
5. Control returns to the main parse at the same position regardless

### Use Cases

Parameter predicates are primarily used for:

1. **Guard Expressions**: Rules that only accept certain parameter values:

   ```dart
   Rule("guarded", (value) {
     return &checkValue(value) >> pattern;
   })
   ```

2. **Semantic Checking**: Validating that captured values meet criteria:

   ```dart
   Rule("check", () {
     return pattern >> &validateCaptures >> nextPattern;
   })
   ```

3. **Dynamic Constraints**: Runtime-determined grammar constraints based on earlier parses

---

## Advanced Scenarios

### Predicate with Complex Patterns

Predicates can wrap any pattern, including sequences and alternations:

```dart
var complexPredicate = Rule("check", () {
  var item = Token.char('a') | Token.char('b');
  var prefix = Token.char('x') >> Token.char('y');
  return (prefix >> item).and() >> actualPattern;
});
```

The sub-parse for this predicate would:

1. Attempt to match 'x' followed by 'y' followed by 'a' or 'b'
2. If successful, return to the main parse at the original position
3. If unsuccessful, the main parse fails

### Nested Predicates

Nesting is supported to arbitrary depth:

```dart
var nested = Rule("nested", () {
  return &(&Token('a') >> Token('b')) >> Token('c');
});
```

The outer AND checks if the inner AND succeeds, which checks if Token('a') exists, which then checks if Token('b') follows. Each layer is tracked via the `predicateStack`.

### Disjunctive Normal Form Manipulation

The compiler can optimize predicates during grammar construction:

```dart
// Original: !(A | B) >> pattern
// Can be transformed to: (!A & !B) >> pattern  (De Morgan's Law)
// This affects how the state machine is structured
```

### Interaction with Ambiguity

Predicates help manage ambiguous grammars by providing zero-width constraints:

```dart
var rule = Rule("stmt", () {
  return &keyword >> identifier      // Not a keyword
       | keyword >> blockStatement;   // Or actual keyword followed by block
});
```

When input could match either branch of the disjunction, the predicates guide the parser to the correct interpretation without backtracking.

### Interaction with Conjunctions

Predicates are distinct from conjunctions (the `&` operator between full patterns):

```dart
// These are different:
&Token('a') >> Token('b')     // Predicate: lookahead for 'a', then consume 'b'
Token('c') & Token('a')       // Conjunction: both 'a' AND 'c' must match
                              // separately at the same position
```

Conjunctions are handled by a separate `ConjunctionTracker`, not the `PredicateTracker`.

---

## Implementation Details

### Frame Queue Processing

At each input position, frames are processed in order:

```dart
for (int pos = 0; pos <= input.length; pos++) {
  // 1. Collect all frames for this position
  var framesAtPos = frameQueue[pos];

  // 2. Process each frame and its current states
  for (var frame in framesAtPos) {
    for (var state in frame.states) {
      var action = state.action;

      if (action is PredicateAction) {
        // Handle predicate according to logic above
      } else if (action is TokenAction) {
        // Handle token consumption
      } else if (action is CallAction) {
        // Handle rule invocation
      }
      // ...
    }
  }

  // 3. Transition to next position
  pos++;
}
```

When a `PredicateAction` is encountered:

- Current frame is examined
- Tracker is consulted or created
- Either frame continues to next state or waits for predicate completion

### Predicate Completion Detection

The parser detects predicate completion through several signals:

1. **Frame Count**: When `activeFrames` becomes zero, all parsing threads in the sub-parse have finished
2. **Position Exhaustion**: When input position reaches end-of-input or maximum matched position
3. **No New Frames**: When queueing frames at the current position produces no new frames at the next position

Once completion is detected:

1. Tracker's `matched` or `exhausted` flags are finalized
2. All `waiters` are retrieved from the tracker
3. Each waiter is resumed as a new frame at the original predicate position

### Predicate Result Caching

Results are cached in the `ParseState.predicateTrackers` map:

```dart
Map<PredicateKey, PredicateTracker> predicateTrackers = {};

// First encounter at (symbol, position)
if (!predicateTrackers.containsKey(key)) {
  var tracker = PredicateTracker(...);
  predicateTrackers[key] = tracker;
  // Spawn sub-parse, add waiters
} else {
  var tracker = predicateTrackers[key]!;
  // Use cached result or add as waiter
}
```

This ensures that each unique `(pattern, position)` pair is only parsed once, even if multiple frames later encounter it through different rule paths.

### Predicate Failures and Backtracking

When a predicate fails:

- For AND predicates: The frame is not requeued, so it effectively dies
- For NOT predicates: The frame proceeds to the next state

This is not backtracking in the traditional sense—the parse stack is never unwound. Instead, frames that fail a predicate simply stop advancing. Frames that succeed continue.

---

## Summary of Key Concepts

| Concept                 | Definition                                                                          |
| ----------------------- | ----------------------------------------------------------------------------------- |
| **Lookahead**           | Examining input without consuming it                                                |
| **AND Predicate**       | `&pattern` - succeeds if pattern matches at current position                        |
| **NOT Predicate**       | `!pattern` - succeeds if pattern does not match                                     |
| **Sub-Parse**           | A separate parsing thread spawned to evaluate a predicate                           |
| **PredicateTracker**    | Object that tracks state and completion of a predicate                              |
| **Predicate Key**       | `(pattern_id, input_position)` - unique identifier for a predicate invocation       |
| **Memoization**         | Caching predicate results so the same predicate at same position isn't re-evaluated |
| **Predicate Stack**     | List of active predicates in nested predicates                                      |
| **Context Inheritance** | Sub-parses inherit arguments and captures from parent parsing                       |
| **Waiter**              | A continuation (frame) waiting for a predicate to complete                          |
| **Active Frames**       | Count of frames still running in a predicate sub-parse                              |

---

## Conclusion

Predicates in Glush are a sophisticated mechanism that enables:

1. **Zero-Width Lookahead**: Checking what's ahead without committing to consume it
2. **Constraint Checking**: Disambiguating ambiguous grammars through semantic and syntactic constraints
3. **Efficient Memoization**: Avoiding redundant predicate evaluation through (pattern, position) caching
4. **Nested Structures**: Supporting arbitrarily nested predicates with proper context tracking
5. **Non-Backtracking Parsing**: Making informed decisions without traditional backtracking

The implementation carefully separates concerns across pattern representation, state machine compilation, and runtime execution, making predicates both powerful and efficient even in complex, ambiguous grammars.
