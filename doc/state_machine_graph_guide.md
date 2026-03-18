# State Machine DOT Graph Generator

## Overview

The `StateMachineGraphGenerator` provides a comprehensive toolkit for visualizing compiled state machines as DOT graphs. This allows you to:

- **Visualize parsing state machines** using Graphviz
- **Analyze state machine structure** with detailed state statistics
- **Understand transitions** between states with labeled edges
- **Identify key states** (initial states, accepting states, dead-ends)
- **Generate reports** on state machine complexity

## Features

### Core Functionality

1. **Full DOT Graph Generation** (`generate()`)
   - Complete state machine visualization with detailed labels
   - Color-coded states (green = initial, pink = accepting)
   - All transition types labeled clearly
   - Support for self-loops and complex state relationships

2. **Simplified DOT Graphs** (`generateSimplified()`)
   - Minimal representation for complex state machines
   - Shows only state structure without detailed labels
   - Useful for large grammars

3. **State Analysis**
   - `getAcceptingStates()` - Find all accepting terminal states
   - `getDeadEndStates()` - Find states with no outgoing transitions
   - `getTransitionCount(state)` - Count transitions from a state
   - `getReachabilityMap()` - Build reachability graph

4. **Statistics & Reports**
   - `generateReport()` - Detailed text report with metrics
   - Total state count and transition count
   - Dead-end state identification
   - Rule-to-state mapping analysis

### Action Types Displayed

The generator visualizes all state action types:

- **Token Actions** - Token matching transitions
- **Mark Actions** - Parse mark assignments
- **Call Actions** - Rule invocation
- **Return Actions** - Rule completion (shown as dashed red self-loops)
- **Semantic Actions** - Callback execution
- **Predicate Actions** - Lookahead assertions (&, !)
- **Accept Actions** - Parse completion

## Usage

### Basic Usage

```dart
import 'package:glush/glush.dart';

// Create and compile a grammar
final grammar = MyGrammar();
final stateMachine = StateMachine(grammar);

// Generate visualization
final generator = stateMachine.createGraphGenerator();
final dotGraph = generator.generate();

// Save and visualize with Graphviz
import 'dart:io';
File('state_machine.dot').writeAsStringSync(dotGraph);

// Command line:
// dot -Tpng state_machine.dot -o state_machine.png
```

### With Custom State Labels

```dart
final customLabels = {
  0: 'InitState',
  5: 'ProcessingToken',
  10: 'WaitingForRule',
};

final generator = stateMachine.createGraphGenerator(
  stateLabels: customLabels,
);
```

### Control Layout Direction

```dart
// Left-to-right (default)
final generator = stateMachine.createGraphGenerator(rankdir: true);

// Top-to-bottom
final generator = stateMachine.createGraphGenerator(rankdir: false);
```

### Analyze State Machine Structure

```dart
final generator = stateMachine.createGraphGenerator();

// Get statistics
final report = generator.generateReport();
print(report);

// Analyze connectivity
final reachability = generator.getReachabilityMap();
final acceptingStates = generator.getAcceptingStates();
final deadEnds = generator.getDeadEndStates();

// Check specific states
final transitionCount = generator.getTransitionCount(state);
```

## DOT Graph Format

The generated DOT graphs use these conventions:

### Node Styling

```
Initial states:
- Shape: circle
- Color: light green (#90EE90)
- Label: "InitX" where X is state ID

Accepting states:
- Shape: double circle (doublecircle)
- Color: light pink (#FFB6C6)
- Label: "AcceptX" where X is state ID

Normal states:
- Shape: circle
- Color: white
- Label: "SX" where X is state ID
```

### Edge Styling

```
Transitions show action type and details:
- "Token: pattern"
- "Mark: name"
- "Call: rule_name"
- "Semantic"
- "Predicate &: pattern"  (for positive lookahead)
- "Predicate !: pattern"  (for negative lookahead)
- "Return: rule_name"     (shown as dashed red self-loop)

Self-loops are shown as dashed lines
```

## Visualization Examples

### Simple Pattern Grammar

```
Initial state (green circle) →
  Token actions for each character →
    Mark actions for tracked positions →
      Final accepting state (pink double circle)
```

### Grammar with Rules

```
Initial state →
  Call action to Rule1 →
    Rule1's state machine →
      Return action back to main path
```

### Complex Grammar with Predicates

```
States with:
- Token actions for terminal symbols
- Call actions for non-terminal rules
- Predicate actions for lookahead assertions
- Mark actions for parse tracking
```

## Command Line Integration

### Generate PNG Image

```bash
dot -Tpng state_machine.dot -o state_machine.png
```

### Generate SVG Image

```bash
dot -Tsvg state_machine.dot -o state_machine.svg
```

### View in Browser

```bash
# macOS
dot -Tsvg state_machine.dot | open -a "Google Chrome" /dev/stdin

# Linux
dot -Tsvg state_machine.dot | firefox /dev/stdin
```

### Generate Multiple Formats

```bash
for fmt in png svg pdf; do
  dot -T$fmt state_machine.dot -o state_machine.$fmt
done
```

## Performance Considerations

- **Time Complexity**: $O(n + m)$ where n = states, m = transitions
- **Space Complexity**: $O(n + m)$ for storing intermediate graph data
- **Reachability Analysis**: Uses BFS, visits each state/transition once
- **Large State Machines**: Use `generateSimplified()` for readability

## Extension Usage

The `StateMachine` class has an extension method for convenience:

```dart
final sm = StateMachine(grammar);

// Instead of:
final gen = StateMachineGraphGenerator(sm);

// Use:
final gen = sm.createGraphGenerator();
```

## Debugging Grammar Issues

Use the graph generator to debug grammar problems:

1. **Dead-end states** indicate unreachable successful parse paths
2. **Excessive transitions** from one state suggest ambiguity
3. **Disconnected components** suggest unreachable rules
4. **Return action loops** show rule call/return structure
5. **Missing accept state** indicates the grammar doesn't match any input properly

## API Reference

### StateMachineGraphGenerator

```dart
class StateMachineGraphGenerator {
  // Constructor
  const StateMachineGraphGenerator(
    StateMachine stateMachine, {
    bool rankdir = true,
    Map<int, String>? stateLabels,
  });

  // Main methods
  String generate();                              // Full detailed graph
  String generateSimplified();                    // Simplified layout
  String generateReport();                        // Statistics report
  
  // Analysis methods
  int getTransitionCount(State state);
  Map<int, Set<int>> getReachabilityMap();
  List<State> getAcceptingStates();
  List<State> getDeadEndStates();
}
```

### Extension Method

```dart
extension StateMachineGraphExt on StateMachine {
  StateMachineGraphGenerator createGraphGenerator({
    bool rankdir = true,
    Map<int, String>? stateLabels,
  });
}
```

## Examples

See `example/state_machine_graph_example.dart` for complete working examples including:
- Simple pattern matching
- Grammars with rules
- Complex nested grammars
- State analysis and reporting

## See Also

- [DOT Language Documentation](https://graphviz.org/doc/info/lang.html)
- [Graphviz Installation](https://graphviz.org/download/)
- [State Machine Documentation](state_machine.dart)
- [Grammar Compilation](grammar.dart)
