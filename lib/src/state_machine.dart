/// State machine compilation from grammars
library glush.state_machine;

import 'package:glush/src/grammar.dart';

import 'patterns.dart';

// Action types for state machine
sealed class StateAction {
  const StateAction();
}

class MarkAction implements StateAction {
  final String name;
  final Pattern pattern;
  final State nextState;

  const MarkAction(this.name, this.pattern, this.nextState);
}

class TokenAction implements StateAction {
  final Pattern pattern;
  final State nextState;

  const TokenAction(this.pattern, this.nextState);
}

class CallAction implements StateAction {
  final Rule rule;
  final Pattern pattern;
  final State returnState;

  const CallAction(this.rule, this.pattern, this.returnState);
}

class ReturnAction implements StateAction {
  final Rule rule;
  final Pattern lastPattern;

  const ReturnAction(this.rule, this.lastPattern);
}

class AcceptAction implements StateAction {
  const AcceptAction();
}

class SemanticAction implements StateAction {
  final Object? Function(String span, List<Object?> childResults) callback;
  final State nextState;
  final Pattern? pattern;

  const SemanticAction(this.callback, this.nextState, [this.pattern]);
}

/// Predicate action for lookahead assertions (AND/NOT predicates)
/// Does not consume input - purely a condition check
class PredicateAction implements StateAction {
  // Marker type: true for AND (&), false for NOT (!)
  final bool isAnd;

  // The pattern to check for the predicate
  final Pattern pattern;

  // The symbol for the pattern (used by shell grammars)
  final PatternSymbol? symbol;

  // Next state after successful predicate check
  final State nextState;

  const PredicateAction({
    required this.isAnd,
    required this.pattern,
    required this.nextState,
    this.symbol,
  });

  @override
  String toString() =>
      isAnd //
      ? 'Predicate(&${symbol ?? pattern})'
      : 'Predicate(!${symbol ?? pattern})';
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

  /// Internal constructor for pre-built state machines (imported)
  /// Used by ImportedStateMachine to reconstruct exported state machines
  StateMachine.empty(this.grammar);

  /// Initialize state structure for imported state machines
  /// (exposed for ImportedStateMachine)
  void initializeImported(List<State> initialStates, Map<Object, State> stateMapping) {
    _initialStates = initialStates;
    _stateMapping.addAll(stateMapping);
    _cachedStates = stateMapping.values.toList();
  }

  StateMachine(this.grammar) {
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
        state.actions.add(ReturnAction(rule, lst));
      }
    }
  }

  State _getOrCreateState(Object pattern) {
    return _stateMapping.putIfAbsent(pattern, () => State(_stateMapping.length));
  }

  State get startState => _stateMapping[':init']!;

  void _connect(State state, Pattern terminal) {
    switch (terminal) {
      case Token() || Conj():
        final nextState = _getOrCreateState(terminal);
        final action = TokenAction(terminal, nextState);
        state.actions.add(action);
      case Marker():
        final nextState = _getOrCreateState(terminal);
        final action = MarkAction(terminal.name, terminal, nextState);
        state.actions.add(action);
      case And():
        // Positive lookahead: create predicate action
        final nextState = _getOrCreateState(terminal);
        final action = PredicateAction(
          isAnd: true,
          pattern: terminal.pattern,
          symbol: terminal.pattern.symbolId,
          nextState: nextState,
        );
        state.actions.add(action);
      case Not():
        // Negative lookahead: create predicate action
        final nextState = _getOrCreateState(terminal);
        final action = PredicateAction(
          isAnd: false,
          pattern: terminal.pattern,
          symbol: terminal.pattern.symbolId,
          nextState: nextState,
        );
        state.actions.add(action);
      case RuleCall(:var rule) || Call(:var rule):
        final returnState = _getOrCreateState(terminal);
        final action = CallAction(rule, terminal, returnState);
        state.actions.add(action);
      case Action<dynamic>():
        // Create a SemanticAction state machine action with the callback
        final nextState = _getOrCreateState(terminal);
        final action = SemanticAction(terminal.callback, nextState, terminal);
        state.actions.add(action);
      case Eps() || Alt() || Seq() || Rule() || Plus() || Star() || Prec():
        // TODO: Handle this case.
        throw UnimplementedError();
    }
  }

  List<State> get states {
    _cachedStates ??= _stateMapping.values.toList();
    return _cachedStates!;
  }

  List<State> get initialStates => _initialStates;
}
