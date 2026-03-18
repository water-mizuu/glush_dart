/// DOT graph generator for state machine visualization
library glush.state_machine_graph;

import 'state_machine.dart';

/// Generates DOT graph representation of state machines for visualization
class StateMachineGraphGenerator {
  final StateMachine stateMachine;
  final bool rankdir;
  final Map<int, String>? stateLabels;

  const StateMachineGraphGenerator(this.stateMachine, {this.rankdir = true, this.stateLabels});

  /// Generate a complete DOT graph string
  String generate() {
    final buffer = StringBuffer();
    buffer.writeln('digraph StateMachine {');
    buffer.writeln('  rankdir=${rankdir ? "LR" : "TB"};');
    buffer.writeln('  node [shape=circle, style=filled, fillcolor=white];');
    buffer.writeln('');

    // Render nodes (states)
    _renderNodes(buffer);
    buffer.writeln('');

    // Render edges (transitions)
    _renderEdges(buffer);

    buffer.writeln('}');
    return buffer.toString();
  }

  void _renderNodes(StringBuffer buffer) {
    final initialStateIds = stateMachine.initialStates.map((s) => s.id).toSet();
    bool hasAccept = false;

    for (final state in stateMachine.states) {
      final attributes = <String, String>{};

      // Check for custom labels first
      if (stateLabels?.containsKey(state.id) ?? false) {
        attributes['label'] = '"${stateLabels![state.id]}"';
      } else if (initialStateIds.contains(state.id)) {
        attributes['shape'] = 'circle';
        attributes['fillcolor'] = '#90EE90'; // Light green
        attributes['label'] = '"Init${state.id}"';
      } else if (state.actions.any((a) => a is AcceptAction)) {
        attributes['shape'] = 'doublecircle';
        attributes['fillcolor'] = '#FFB6C6'; // Light pink
        attributes['label'] = '"Accept${state.id}"';
        hasAccept = true;
      } else {
        attributes['label'] = '"S${state.id}"';
      }

      // Apply styling for initial and accepting states even with custom labels
      if (initialStateIds.contains(state.id)) {
        attributes['shape'] = 'circle';
        attributes['fillcolor'] = '#90EE90'; // Light green
      } else if (state.actions.any((a) => a is AcceptAction)) {
        attributes['shape'] = 'doublecircle';
        attributes['fillcolor'] = '#FFB6C6'; // Light pink
        hasAccept = true;
      }

      final attrStr = attributes.entries
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      buffer.writeln('  S${state.id} [$attrStr];');
    }

    if (!hasAccept && stateMachine.states.isNotEmpty) {
      buffer.writeln('  // No accepting states found');
    }
  }

  void _renderEdges(StringBuffer buffer) {
    for (final state in stateMachine.states) {
      for (final action in state.actions) {
        switch (action) {
          case TokenAction(:var pattern, :var nextState):
            _addEdge(buffer, state, nextState, 'Token: $pattern');
          case MarkAction(:var name, :var nextState):
            _addEdge(buffer, state, nextState, 'Mark: $name');
          case CallAction(:var rule, :var returnState):
            _addEdge(buffer, state, returnState, 'Call: ${rule.name}');
          case ReturnAction(:var rule):
            // Return actions don't transition to another state, they return from a rule
            buffer.writeln(
              '  S${state.id} -> S${state.id} [label="Return: ${rule.name}", style=dashed, color=red];',
            );
          case AcceptAction():
            // Accept actions don't create transitions
            break;
          case SemanticAction(:var nextState):
            _addEdge(buffer, state, nextState, 'Semantic');
          case PredicateAction(:var isAnd, :var pattern, :var nextState):
            final predType = isAnd ? '&' : '!';
            _addEdge(buffer, state, nextState, 'Predicate $predType: $pattern');
        }
      }
    }
  }

  void _addEdge(StringBuffer buffer, State from, State to, String label) {
    final style = from.id == to.id ? 'style=dashed, ' : '';
    buffer.writeln('  S${from.id} -> S${to.id} [label="$label", ${style}fontsize=9];');
  }

  /// Generate a simplified DOT graph with fewer details
  String generateSimplified() {
    final buffer = StringBuffer();
    buffer.writeln('digraph StateMachine {');
    buffer.writeln('  rankdir=LR;');
    buffer.writeln('  node [shape=circle];');
    buffer.writeln('');

    final initialStateIds = stateMachine.initialStates.map((s) => s.id).toSet();

    // Nodes
    for (final state in stateMachine.states) {
      if (initialStateIds.contains(state.id)) {
        buffer.writeln('  S${state.id} [shape=circle, fillcolor=lightgreen, style=filled];');
      } else if (state.actions.any((a) => a is AcceptAction)) {
        buffer.writeln('  S${state.id} [shape=doublecircle, fillcolor=lightpink, style=filled];');
      }
    }

    // Edges
    final edgeSet = <String>{};
    for (final state in stateMachine.states) {
      for (final action in state.actions) {
        State? nextState;
        if (action is TokenAction)
          nextState = action.nextState;
        else if (action is MarkAction)
          nextState = action.nextState;
        else if (action is CallAction)
          nextState = action.returnState;
        else if (action is SemanticAction)
          nextState = action.nextState;
        else if (action is PredicateAction)
          nextState = action.nextState;

        if (nextState != null) {
          final edgeKey = 'S${state.id} -> S${nextState.id}';
          edgeSet.add(edgeKey);
        }
      }
    }

    for (final edge in edgeSet) {
      buffer.writeln('  $edge;');
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  /// Get transition count for a state
  int getTransitionCount(State state) {
    return state.actions
        .where(
          (a) =>
              a is TokenAction ||
              a is MarkAction ||
              a is CallAction ||
              a is SemanticAction ||
              a is PredicateAction,
        )
        .length;
  }

  /// Get reachability map showing which states can reach which
  Map<int, Set<int>> getReachabilityMap() {
    final reachability = <int, Set<int>>{};

    for (final state in stateMachine.states) {
      reachability[state.id] = {};
    }

    // BFS from each state
    for (final startState in stateMachine.states) {
      final visited = <int>{};
      final queue = <State>[startState];

      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        if (visited.contains(current.id)) continue;
        visited.add(current.id);

        for (final action in current.actions) {
          State? nextState;
          if (action is TokenAction)
            nextState = action.nextState;
          else if (action is MarkAction)
            nextState = action.nextState;
          else if (action is CallAction)
            nextState = action.returnState;
          else if (action is SemanticAction)
            nextState = action.nextState;
          else if (action is PredicateAction)
            nextState = action.nextState;

          if (nextState != null && !visited.contains(nextState.id)) {
            reachability[startState.id]!.add(nextState.id);
            queue.add(nextState);
          }
        }
      }
    }

    return reachability;
  }

  /// Find all accepting states
  List<State> getAcceptingStates() {
    return stateMachine.states.where((s) => s.actions.any((a) => a is AcceptAction)).toList();
  }

  /// Find dead-end states (no outgoing transitions)
  List<State> getDeadEndStates() {
    return stateMachine.states.where((s) {
      final hasTransition = s.actions.any(
        (a) =>
            a is TokenAction ||
            a is MarkAction ||
            a is CallAction ||
            a is SemanticAction ||
            a is PredicateAction,
      );
      return !hasTransition && s.actions.every((a) => a is! AcceptAction);
    }).toList();
  }

  /// Generate a report of state machine statistics
  String generateReport() {
    final buffer = StringBuffer();
    buffer.writeln('State Machine Analysis Report');
    buffer.writeln('=' * 40);
    buffer.writeln('Total states: ${stateMachine.states.length}');
    buffer.writeln('Initial states: ${stateMachine.initialStates.length}');
    buffer.writeln('Accepting states: ${getAcceptingStates().length}');
    buffer.writeln('Dead-end states: ${getDeadEndStates().length}');
    buffer.writeln('');

    buffer.writeln('Rules: ${stateMachine.rules.length}');
    for (final rule in stateMachine.rules) {
      final firstStates = stateMachine.ruleFirst[rule];
      buffer.writeln('  - ${rule.name}: ${firstStates?.length ?? 0} first state(s)');
    }
    buffer.writeln('');

    int totalTransitions = 0;
    int maxTransitionsPerState = 0;
    for (final state in stateMachine.states) {
      final count = getTransitionCount(state);
      totalTransitions += count;
      maxTransitionsPerState = count > maxTransitionsPerState ? count : maxTransitionsPerState;
    }
    buffer.writeln('Total transitions: $totalTransitions');
    buffer.writeln('Max transitions per state: $maxTransitionsPerState');

    return buffer.toString();
  }
}

/// Extension for easy access to graph generation
extension StateMachineGraphExt on StateMachine {
  /// Create a graph generator for this state machine
  StateMachineGraphGenerator createGraphGenerator({
    bool rankdir = true,
    Map<int, String>? stateLabels,
  }) {
    return StateMachineGraphGenerator(this, rankdir: rankdir, stateLabels: stateLabels);
  }
}
