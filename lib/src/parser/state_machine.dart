/// State machine compilation from grammars
library glush.state_machine;

import 'package:glush/src/core/grammar.dart';

import '../core/patterns.dart';

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
  final int? minPrecedenceLevel;

  const CallAction(this.rule, this.pattern, this.returnState, [this.minPrecedenceLevel]);

  @override
  String toString() => minPrecedenceLevel != null
      ? 'CallAction(${rule.name}^$minPrecedenceLevel)'
      : 'CallAction(${rule.name})';
}

class ReturnAction implements StateAction {
  final Rule rule;
  final Pattern lastPattern;
  final int? precedenceLevel;

  const ReturnAction(this.rule, this.lastPattern, [this.precedenceLevel]);

  @override
  String toString() => precedenceLevel != null
      ? 'ReturnAction(${rule.name}, prec: $precedenceLevel)'
      : 'ReturnAction(${rule.name})';
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

  // The symbol for the pattern (used by shell grammars)
  final PatternSymbol symbol;

  // Next state after successful predicate check
  final State nextState;

  const PredicateAction({required this.isAnd, required this.symbol, required this.nextState});

  @override
  String toString() =>
      isAnd //
      ? 'Predicate(&$symbol)'
      : 'Predicate(!$symbol)';
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
  final List<PatternSymbol> rules = [];
  final Map<PatternSymbol, List<State>> ruleFirst = {};
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
      rules.add(rule.symbolId!);

      final firstState = _getOrCreateState(rule);
      ruleFirst[rule.symbolId!] = [firstState];

      // Pre-calculate precedence mapping for this rule's body
      final precMap = <Pattern, int?>{};
      _buildPrecedenceMap(rule.body(), null, precMap);

      // Connect to first patterns
      for (final firstStateInRange in rule.body().firstSet()) {
        _connect(firstState, firstStateInRange);
      }

      // Connect each pair
      rule.body().eachPair((a, b) {
        _connect(_getOrCreateState(a), b);
      });

      // Mark states before returns
      for (final lastState in rule.body().lastSet()) {
        final state = _getOrCreateState(lastState);
        state.actions.add(ReturnAction(rule, lastState, precMap[lastState]));
      }
      if (rule.body().empty()) {
        firstState.actions.add(ReturnAction(rule, Eps()));
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
          symbol: switch (terminal.pattern) {
            RuleCall(:var rule) => rule.symbolId!,
            _ => throw UnsupportedError('Invalid pattern type for predicate action'),
          },
          nextState: nextState,
        );
        state.actions.add(action);
      case Not():
        // Negative lookahead: create predicate action
        final nextState = _getOrCreateState(terminal);
        final action = PredicateAction(
          isAnd: false,
          symbol: (terminal.pattern as RuleCall).rule.symbolId!,
          nextState: nextState,
        );
        state.actions.add(action);
      case RuleCall(:var rule):
        final returnState = _getOrCreateState(terminal);
        // Get minPrecedenceLevel from Call/RuleCall
        final minPrecedenceLevel = terminal.minPrecedenceLevel;
        final action = CallAction(rule, terminal, returnState, minPrecedenceLevel);
        state.actions.add(action);
      case Action<dynamic>():
        // Create a SemanticAction state machine action with the callback
        final nextState = _getOrCreateState(terminal);
        final action = SemanticAction(terminal.callback, nextState, terminal);
        state.actions.add(action);
      case Eps():
        // Epsilon doesn't create transitions
        break;
      case Alt() || Seq() || Rule() || Prec():
        // These should have been decomposed by Glushkov construction
        throw UnimplementedError('Unexpected pattern type in _connect: ${terminal.runtimeType}');
    }
  }

  void _buildPrecedenceMap(Pattern pattern, int? current, Map<Pattern, int?> map) {
    if (pattern is Prec) {
      _buildPrecedenceMap(pattern.child, pattern.precedenceLevel, map);
      return;
    }

    // Leaf nodes or other nodes that might be in lastSet()
    map[pattern] = current;

    if (pattern is Alt) {
      _buildPrecedenceMap(pattern.left, current, map);
      _buildPrecedenceMap(pattern.right, current, map);
    } else if (pattern is Seq) {
      _buildPrecedenceMap(pattern.left, current, map);
      _buildPrecedenceMap(pattern.right, current, map);
    } else if (pattern is Action) {
      _buildPrecedenceMap(pattern.child, current, map);
    }
  }

  List<State> get states {
    _cachedStates ??= _stateMapping.values.toList();
    return _cachedStates!;
  }

  List<State> get initialStates => _initialStates;
}
