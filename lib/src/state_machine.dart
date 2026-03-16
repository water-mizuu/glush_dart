/// State machine compilation from grammars
library glush.state_machine;

import 'patterns.dart';
import 'errors.dart';

// Grammar interface to avoid circular import
abstract class GrammarInterface {
  /// Maps symbol IDs back to patterns for this grammar
  Map<String, Pattern> get symbolRegistry;

  RuleCall get startCall;
  List<Rule> get rules;
  bool isEmpty();
}

// Action types for state machine
abstract class StateAction {
  const StateAction();
}

class MarkAction implements StateAction {
  final String name;
  final State nextState;

  const MarkAction(this.name, this.nextState);
}

class TokenAction implements StateAction {
  final Pattern pattern;
  final State nextState;

  const TokenAction(this.pattern, this.nextState);
}

class CallAction implements StateAction {
  final Rule rule;
  final State returnState;

  const CallAction(this.rule, this.returnState);
}

class ReturnAction implements StateAction {
  final Rule rule;

  const ReturnAction(this.rule);
}

class AcceptAction implements StateAction {
  const AcceptAction();
}

class SemanticAction implements StateAction {
  final dynamic Function(String span, List<dynamic> childResults) callback;
  final State nextState;
  final Pattern? childPattern;

  const SemanticAction(this.callback, this.nextState, [this.childPattern]);
}

/// Predicate action for lookahead assertions (AND/NOT predicates)
/// Does not consume input - purely a condition check
class PredicateAction implements StateAction {
  // Marker type: true for AND (&), false for NOT (!)
  final bool isAnd;

  // The pattern to check for the predicate
  final Pattern pattern;

  // Next state after successful predicate check
  final State nextState;

  const PredicateAction({
    required this.isAnd,
    required this.pattern,
    required this.nextState,
  });

  @override
  String toString() => isAnd ? 'Predicate(&${pattern})' : 'Predicate(!${pattern})';
}

/// State in the state machine
class State {
  final int id;
  final List<StateAction> actions = [];

  State(this.id);

  @override
  String toString() => 'State($id)';
}

/// The compiled state machine
class StateMachine {
  final GrammarInterface grammar;
  final List<Rule> rules = [];
  final Map<Rule, List<State>> ruleFirst = {};
  List<State>? _cachedStates;
  late final List<State> _initialStates;

  final Map<Object, State> _stateMapping = {};
  final Map<String, dynamic Function(String, List<dynamic>)> _actionCallbacks = {};
  final Map<Pattern, String> _patternActions = {}; // Maps child patterns to action IDs
  int _actionIdCounter = 0;

  StateMachine(this.grammar) {
    _buildStateMachine();
  }

  void _buildStateMachine() {
    final initState = _getOrCreateState(':init');
    _connect(initState, grammar.startCall);

    // Mark the state after start call as accepting
    final startState = _getOrCreateState(grammar.startCall);
    startState.actions.add(const AcceptAction());

    if (grammar.isEmpty()) {
      initState.actions.add(const AcceptAction());
    }

    _initialStates = [initState];

    // Process each rule
    for (final rule in grammar.rules) {
      rules.add(rule);

      // First, extract all actions from the rule body
      _extractActions(rule.body());

      final firstState = _getOrCreateState(rule);
      ruleFirst[rule] = [firstState];

      // Connect to first patterns
      for (final fst in rule.body().firstSet()) {
        _connect(firstState, fst);
      }

      // Connect each pair
      rule.body().eachPair((a, b) {
        _connect(_getOrCreateState(a), b);
      });

      // Mark states before returns
      for (final lst in rule.body().lastSet()) {
        final state = _getOrCreateState(lst);
        state.actions.add(ReturnAction(rule));
      }
    }
  }

  void _extractActions(Pattern pattern) {
    if (pattern is Action) {
      final actionId = '_action_${_actionIdCounter++}';
      _actionCallbacks[actionId] = pattern.callback;
      _patternActions[pattern.child] = actionId;
      _extractActions(pattern.child);
    } else if (pattern is Alt) {
      _extractActions(pattern.left);
      _extractActions(pattern.right);
    } else if (pattern is Seq) {
      _extractActions(pattern.left);
      _extractActions(pattern.right);
    } else if (pattern is Plus) {
      _extractActions(pattern.child);
    } else if (pattern is And) {
      _extractActions(pattern.pattern);
    } else if (pattern is Not) {
      _extractActions(pattern.pattern);
    }
  }

  State _getOrCreateState(Object pattern) {
    if (pattern is String) {
      return _stateMapping.putIfAbsent(
        pattern,
        () => State(_stateMapping.length),
      );
    }
    return _stateMapping.putIfAbsent(
      pattern,
      () => State(_stateMapping.length),
    );
  }

  void _connect(State state, Pattern terminal) {
    if (terminal is Action) {
      // Extract action callback and register it with the child pattern
      final actionId = '_action_${_actionIdCounter++}';
      _actionCallbacks[actionId] = terminal.callback;
      // Mark the child pattern as having this action
      _patternActions[terminal.child] = actionId;
      // Now process the child pattern normally
      _connect(state, terminal.child);
    } else if (terminal is RuleCall) {
      final returnState = _getOrCreateState(terminal);
      final action = CallAction(terminal.rule, returnState);
      state.actions.add(action);
    } else if (terminal is Call) {
      final returnState = _getOrCreateState(terminal);
      final action = CallAction(terminal.rule, returnState);
      state.actions.add(action);
    } else if (terminal is And) {
      // Positive lookahead: create predicate action
      final nextState = _getOrCreateState(terminal);
      final action = PredicateAction(isAnd: true, pattern: terminal.pattern, nextState: nextState);
      state.actions.add(action);
    } else if (terminal is Not) {
      // Negative lookahead: create predicate action
      final nextState = _getOrCreateState(terminal);
      final action = PredicateAction(isAnd: false, pattern: terminal.pattern, nextState: nextState);
      state.actions.add(action);
    } else if (terminal is Token || terminal is Conj) {
      final nextState = _getOrCreateState(terminal);
      final action = TokenAction(terminal, nextState);
      state.actions.add(action);
    } else if (terminal is Marker) {
      final nextState = _getOrCreateState(terminal);
      final action = MarkAction(terminal.name, nextState);
      state.actions.add(action);
    } else {
      throw GrammarError('Unknown terminal: ${terminal.runtimeType}');
    }
  }

  List<State> get states {
    _cachedStates ??= _stateMapping.values.toList();
    return _cachedStates!;
  }

  List<State> get initialStates => _initialStates;

  Map<String, dynamic Function(String, List<dynamic>)> get actionCallbacks => _actionCallbacks;

  Map<Pattern, String> get patternActions => _patternActions;
}
