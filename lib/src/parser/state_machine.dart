/// State machine compilation from grammars
library glush.state_machine;

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Key for identifying states in the state machine.
@immutable
sealed class StateKey {
  const StateKey();
}

final class InitStateKey extends StateKey {
  const InitStateKey();

  @override
  bool operator ==(Object other) => other is InitStateKey;

  @override
  int get hashCode => (InitStateKey).hashCode;

  @override
  String toString() => ":init";
}

final class PatternStateKey extends StateKey {
  const PatternStateKey(this.pattern);
  final Pattern pattern;

  @override
  bool operator ==(Object other) => other is PatternStateKey && other.pattern == pattern;

  @override
  int get hashCode => pattern.hashCode;

  @override
  String toString() => pattern.toString();
}

final class ParamStringStateKey extends StateKey {
  const ParamStringStateKey(this.text, this.index, this.nextState);
  final String text;
  final int index;
  final State nextState;

  @override
  bool operator ==(Object other) =>
      other is ParamStringStateKey &&
      other.text == text &&
      other.index == index &&
      other.nextState == nextState;

  @override
  int get hashCode => Object.hash(text, index, nextState);
}

final class ParamPredicateStateKey extends StateKey {
  const ParamPredicateStateKey(this.text, this.index);
  final String text;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is ParamPredicateStateKey && other.text == text && other.index == index;

  @override
  int get hashCode => Object.hash(text, index);
}

final class ParamPredicateEndStateKey extends StateKey {
  const ParamPredicateEndStateKey(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is ParamPredicateEndStateKey && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

// Action types for state machine
@immutable
sealed class StateAction {
  const StateAction();
}

final class MarkAction implements StateAction {
  MarkAction(this.name, this.pattern, this.nextState)
    : _hash = Object.hash(MarkAction, name, pattern, nextState);
  final String name;
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkAction &&
          name == other.name &&
          pattern == other.pattern &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;
}

final class TokenAction implements StateAction {
  TokenAction(this.pattern, this.nextState) : _hash = Object.hash(TokenAction, pattern, nextState);
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenAction && pattern == other.pattern && nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "Token($pattern)";
}

enum BoundaryKind { start, eof }

final class BoundaryAction implements StateAction {
  BoundaryAction(this.kind, this.pattern, this.nextState)
    : _hash = Object.hash(BoundaryAction, kind, pattern, nextState);
  final BoundaryKind kind;
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BoundaryAction &&
          kind == other.kind &&
          pattern == other.pattern &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;
}

String _describeRuleCall(RuleCall call, [int? minPrecedenceLevel]) {
  var description = call.toString();
  if (description.startsWith("<") && description.endsWith(">")) {
    description = description.substring(1, description.length - 1);
  }
  var prec = minPrecedenceLevel ?? call.minPrecedenceLevel;
  if (prec == null) {
    return description;
  }
  if (description.contains("^")) {
    return description;
  }
  return "$description^$prec";
}

final class LabelStartAction implements StateAction {
  LabelStartAction(this.name, this.pattern, this.nextState)
    : _hash = Object.hash(LabelStartAction, name, pattern, nextState);
  final String name;
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelStartAction &&
          name == other.name &&
          pattern == other.pattern &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;
}

final class LabelEndAction implements StateAction {
  LabelEndAction(this.name, this.pattern, this.nextState)
    : _hash = Object.hash(LabelEndAction, name, pattern, nextState);
  final String name;
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelEndAction &&
          name == other.name &&
          pattern == other.pattern &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;
}

final class ParameterAction implements StateAction {
  ParameterAction(this.name, this.pattern, this.nextState)
    : _hash = Object.hash(ParameterAction, name, pattern, nextState);
  final String name;
  final Pattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParameterAction &&
          name == other.name &&
          pattern == other.pattern &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "Parameter($name)";
}

final class ParameterCallAction implements StateAction {
  ParameterCallAction(this.pattern, this.nextState)
    : _hash = Object.hash(ParameterCallAction, pattern, nextState);

  final ParameterCallPattern pattern;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParameterCallAction && pattern == other.pattern && nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "ParameterCall($pattern)";
}

final class ParameterStringAction implements StateAction {
  const ParameterStringAction(this.codeUnit, this.nextState);
  final int codeUnit;
  final State nextState;

  @override
  String toString() => "ParameterString(${String.fromCharCode(codeUnit)})";
}

final class ParameterPredicateAction implements StateAction {
  const ParameterPredicateAction({
    required this.isAnd,
    required this.name,
    required this.nextState,
  });

  final bool isAnd;
  final String name;
  final State nextState;

  @override
  String toString() => isAnd ? "ParameterPredicate(&$name)" : "ParameterPredicate(!$name)";
}

final class CallAction implements StateAction {
  CallAction(this.rule, this.pattern, this.returnState, [this.minPrecedenceLevel])
    : _hash = Object.hash(CallAction, rule, pattern, returnState, minPrecedenceLevel);
  final Rule rule;
  final Pattern pattern;
  final State returnState;
  final int? minPrecedenceLevel;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallAction &&
          rule == other.rule &&
          pattern == other.pattern &&
          returnState == other.returnState &&
          minPrecedenceLevel == other.minPrecedenceLevel;

  @override
  int get hashCode => _hash;

  @override
  String toString() => switch (pattern) {
    RuleCall() => "CallAction(${_describeRuleCall(pattern as RuleCall, minPrecedenceLevel)})",
    _ =>
      minPrecedenceLevel != null
          ? "CallAction(${rule.name}^$minPrecedenceLevel)"
          : "CallAction(${rule.name})",
  };
}

final class TailCallAction implements StateAction {
  TailCallAction(this.rule, this.pattern, [this.minPrecedenceLevel])
    : _hash = Object.hash(TailCallAction, rule, pattern, minPrecedenceLevel);
  final Rule rule;
  final Pattern pattern;
  final int? minPrecedenceLevel;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TailCallAction &&
          rule == other.rule &&
          pattern == other.pattern &&
          minPrecedenceLevel == other.minPrecedenceLevel;

  @override
  int get hashCode => _hash;

  @override
  String toString() => switch (pattern) {
    RuleCall() => "TailCallAction(${_describeRuleCall(pattern as RuleCall, minPrecedenceLevel)})",
    _ =>
      minPrecedenceLevel != null
          ? "TailCallAction(${rule.name}^$minPrecedenceLevel)"
          : "TailCallAction(${rule.name})",
  };
}

final class ReturnAction implements StateAction {
  ReturnAction(this.rule, this.lastPattern, [this.precedenceLevel])
    : _hash = Object.hash(ReturnAction, rule, lastPattern, precedenceLevel);
  final Rule rule;
  final Pattern lastPattern;
  final int? precedenceLevel;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReturnAction &&
          rule == other.rule &&
          lastPattern == other.lastPattern &&
          precedenceLevel == other.precedenceLevel;

  @override
  int get hashCode => _hash;

  @override
  String toString() => precedenceLevel != null
      ? "ReturnAction(${rule.name}, prec: $precedenceLevel)"
      : "ReturnAction(${rule.name})";
}

final class AcceptAction implements StateAction {
  const AcceptAction();
}

/// Predicate action for lookahead assertions (AND/NOT predicates)
/// Does not consume input - purely a condition check
final class PredicateAction implements StateAction {
  PredicateAction({required this.isAnd, required this.symbol, required this.nextState})
    : _hash = Object.hash(PredicateAction, isAnd, symbol, nextState);

  // Marker type: true for AND (&), false for NOT (!)
  final bool isAnd;

  // The symbol for the pattern (used by shell grammars)
  final PatternSymbol symbol;

  // Next state after successful predicate check
  final State nextState;

  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PredicateAction &&
          isAnd == other.isAnd &&
          symbol == other.symbol &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() =>
      isAnd //
      ? "Predicate(&$symbol)"
      : "Predicate(!$symbol)";
}

/// Conjunction action for consuming intersection (A & B)
final class ConjunctionAction implements StateAction {
  ConjunctionAction({required this.leftSymbol, required this.rightSymbol, required this.nextState})
    : _hash = Object.hash(ConjunctionAction, leftSymbol, rightSymbol, nextState);

  final PatternSymbol leftSymbol;
  final PatternSymbol rightSymbol;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConjunctionAction &&
          leftSymbol == other.leftSymbol &&
          rightSymbol == other.rightSymbol &&
          nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "Conj($leftSymbol & $rightSymbol)";
}

/// Negation action for consuming complement (¬A)
final class NegationAction implements StateAction {
  NegationAction({required this.symbol, required this.nextState})
    : _hash = Object.hash(NegationAction, symbol, nextState);

  final PatternSymbol symbol;
  final State nextState;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NegationAction && symbol == other.symbol && nextState == other.nextState;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "Neg($symbol)";
}

/// State in the state machine
class State {
  State(this.id);
  final int id;
  final List<StateAction> actions = [];

  @override
  String toString() => "State($id)";
}

final class _PredicateCluster {
  const _PredicateCluster({
    required this.rule,
    required this.label,
    required this.states,
    required this.terminalStates,
  });
  final Rule rule;
  final String label;
  final List<State> states;
  final List<State> terminalStates;
}

/// The compiled state machine
class StateMachine {
  StateMachine(this.grammar) {
    var initState = _getOrCreateState(const InitStateKey());
    _connect(initState, grammar.startCall);

    // Mark the state after start call as accepting
    var startState = _getOrCreateState(PatternStateKey(grammar.startCall));
    startState.actions.add(const AcceptAction());

    if (grammar.isEmpty()) {
      initState.actions.add(const AcceptAction());
    }

    _initialStates = [initState];

    // Process each rule
    for (var rule in grammar.rules) {
      assert(
        rule.symbolId != null,
        "Invariant violation in StateMachine: rule.symbolId must be assigned before compilation.",
      );
      rules.add(rule.symbolId!);

      var firstState = _getOrCreateState(PatternStateKey(rule));
      ruleFirst[rule.symbolId!] = [firstState];
      _tailSelfCalls[rule] = _findDirectTailSelfCalls(rule);

      // Pre-calculate precedence mapping for this rule's body
      var precMap = <Pattern, int?>{};
      _buildPrecedenceMap(rule.body(), null, precMap);

      // Connect to first patterns
      for (var firstStateInRange in rule.body().firstSet()) {
        _connect(firstState, firstStateInRange, currentRule: rule);
      }

      // Connect each pair
      rule.body().eachPair((a, b) {
        _connect(_getOrCreateState(PatternStateKey(a)), b, currentRule: rule);
      });

      // Mark states before returns
      for (var lastState in rule.body().lastSet()) {
        var state = _getOrCreateState(PatternStateKey(lastState));
        var action = ReturnAction(rule, lastState, precMap[lastState]);
        state.actions.add(action);
      }
      if (rule.body().empty()) {
        firstState.actions.add(ReturnAction(rule, Eps()));
      }
    }
  }

  /// Internal constructor for pre-built state machines (imported)
  /// Used by ImportedStateMachine to reconstruct exported state machines
  StateMachine.empty(this.grammar);
  final GrammarInterface grammar;
  final List<PatternSymbol> rules = [];
  final Map<PatternSymbol, List<State>> ruleFirst = {};
  List<State>? _cachedStates;
  late final List<State> _initialStates;
  final Map<(String, State), State> _parameterStringChains = {};
  final Map<String, State> _parameterPredicateChains = {};
  final Rule _parameterPredicateRule = Rule("_parameter_predicate", () => Eps());

  final Map<StateKey, State> _stateMapping = {};
  final Map<Rule, Set<RuleCall>> _tailSelfCalls = {};

  /// Initialize state structure for imported state machines
  /// (exposed for ImportedStateMachine)
  void initializeImported(List<State> initialStates, Map<StateKey, State> stateMapping) {
    _initialStates = initialStates;
    _stateMapping.addAll(stateMapping);
    _cachedStates = stateMapping.values.toList();
  }

  State _getOrCreateState(StateKey key) {
    var state = _stateMapping[key];
    if (state != null) {
      return state;
    }
    var created = State(_stateMapping.length);
    _stateMapping[key] = created;
    _cachedStates = null;
    return created;
  }

  State get startState => _stateMapping[const InitStateKey()]!;

  State parameterStringEntry(String text, State nextState) {
    if (text.isEmpty) {
      return nextState;
    }

    var key = (text, nextState);
    if (_parameterStringChains[key] case var state?) {
      return state;
    }

    var tail = nextState;
    for (var i = text.codeUnits.length - 1; i >= 0; i--) {
      var state = _getOrCreateState(ParamStringStateKey(text, i, nextState));
      if (state.actions.isEmpty) {
        state.actions.add(ParameterStringAction(text.codeUnits[i], tail));
      }
      tail = state;
    }
    return _parameterStringChains[key] = tail;
  }

  State parameterPredicateEntry(String text) {
    // Predicates use the same cached chain idea, but end in a synthetic
    // return state so lookahead can resume the caller if the predicate matches.

    if (_parameterPredicateChains[text] case var state?) {
      return state;
    }

    var terminal = _getOrCreateState(ParamPredicateEndStateKey(text));
    if (terminal.actions.isEmpty) {
      terminal.actions.add(ReturnAction(_parameterPredicateRule, Eps()));
    }

    if (text.isEmpty) {
      return terminal;
    }

    var tail = terminal;
    for (var i = text.codeUnits.length - 1; i >= 0; i--) {
      var state = _getOrCreateState(ParamPredicateStateKey(text, i));
      if (state.actions.isEmpty) {
        state.actions.add(ParameterStringAction(text.codeUnits[i], tail));
      }
      tail = state;
    }
    return _parameterPredicateChains[text] = tail;
  }

  void _connect(State state, Pattern terminal, {Rule? currentRule}) {
    switch (terminal) {
      case Token():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = TokenAction(terminal, nextState);
        state.actions.add(action);
      case Conj():
        if (terminal.singleToken()) {
          var nextState = _getOrCreateState(PatternStateKey(terminal));
          var action = TokenAction(terminal, nextState);
          state.actions.add(action);
        } else {
          var nextState = _getOrCreateState(PatternStateKey(terminal));
          // Complex conjunction: use sub-parse rendezvous
          var action = ConjunctionAction(
            leftSymbol: _extractSymbol(terminal.left),
            rightSymbol: _extractSymbol(terminal.right),
            nextState: nextState,
          );
          state.actions.add(action);
        }
      case StartAnchor() || EofAnchor():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var kind = terminal is StartAnchor ? BoundaryKind.start : BoundaryKind.eof;
        var action = BoundaryAction(kind, terminal, nextState);
        state.actions.add(action);
      case Marker():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = MarkAction(terminal.name, terminal, nextState);
        state.actions.add(action);
      case And():
        // Positive lookahead: create predicate action
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        switch (terminal.pattern) {
          case RuleCall(:var rule):
            state.actions.add(
              PredicateAction(isAnd: true, symbol: rule.symbolId!, nextState: nextState),
            );
          case ParameterRefPattern(:var name):
            // Parameter lookahead is resolved from the current caller
            // arguments, which lets `&param` inspect dynamic parser data.
            state.actions.add(
              ParameterPredicateAction(isAnd: true, name: name, nextState: nextState),
            );
          default:
            throw UnsupportedError("Invalid pattern type for predicate action");
        }
      case Not():
        // Negative lookahead: create predicate action
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        switch (terminal.pattern) {
          case RuleCall(:var rule):
            state.actions.add(
              PredicateAction(isAnd: false, symbol: rule.symbolId!, nextState: nextState),
            );
          case ParameterRefPattern(:var name):
            // Negative parameter predicates use the same runtime resolution
            // path, but only resume when the value does *not* match.
            state.actions.add(
              ParameterPredicateAction(isAnd: false, name: name, nextState: nextState),
            );
          default:
            throw UnsupportedError("Invalid pattern type for predicate action");
        }
      case Neg():
        // Span-level negation: create negation action
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = NegationAction(
          symbol: (terminal.pattern as RuleCall).rule.symbolId!,
          nextState: nextState,
        );
        state.actions.add(action);
      case RuleCall():
        var minPrecedenceLevel = terminal.minPrecedenceLevel;
        if (currentRule != null &&
            minPrecedenceLevel == null &&
            (_tailSelfCalls[currentRule]?.contains(terminal) ?? false)) {
          var action = TailCallAction(terminal.rule, terminal, minPrecedenceLevel);
          state.actions.add(action);
        } else {
          var returnState = _getOrCreateState(PatternStateKey(terminal));
          var action = CallAction(terminal.rule, terminal, returnState, minPrecedenceLevel);
          state.actions.add(action);
        }
      case LabelStart():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = LabelStartAction(terminal.name, terminal, nextState);
        state.actions.add(action);
      case LabelEnd():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = LabelEndAction(terminal.name, terminal, nextState);
        state.actions.add(action);
      case ParameterRefPattern():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = ParameterAction(terminal.name, terminal, nextState);
        state.actions.add(action);
      case ParameterCallPattern():
        var nextState = _getOrCreateState(PatternStateKey(terminal));
        var action = ParameterCallAction(terminal, nextState);
        state.actions.add(action);
      case Eps():
        // Epsilon doesn't create transitions
        break;
      case Action() || Alt() || Seq() || Rule() || Prec() || Label() || Opt() || Plus() || Star():
        // These should have been decomposed by Glushkov construction
        throw UnimplementedError("Unexpected pattern type in _connect: ${terminal.runtimeType}");
    }
  }

  PatternSymbol _extractSymbol(Pattern pattern) {
    return switch (pattern) {
      RuleCall(:var rule) => rule.symbolId!,
      _ => throw UnsupportedError("Conjunction children must be rules or tokens: $pattern"),
    };
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
    } else if (pattern is Label) {
      _buildPrecedenceMap(pattern.child, current, map);
      map[pattern] = current;
      assert(
        pattern.firstSet().isNotEmpty && pattern.lastSet().isNotEmpty,
        "Invariant violation in _buildPrecedenceMap: Label must expose non-empty "
        "first/last sets for precedence propagation.",
      );
      map[pattern.firstSet().first] = current;
      map[pattern.lastSet().first] = current;
    } else if (pattern is Opt) {
      _buildPrecedenceMap(pattern.child, current, map);
    } else if (pattern is Plus) {
      _buildPrecedenceMap(pattern.child, current, map);
    } else if (pattern is Star) {
      _buildPrecedenceMap(pattern.child, current, map);
    }
  }

  List<State> get states {
    _cachedStates ??= _stateMapping.values.toList();
    return _cachedStates!;
  }

  List<State> get initialStates => _initialStates;

  /// Render the compiled state machine as Graphviz DOT.
  ///
  /// The export includes synthetic start/accept nodes so the entry and exit
  /// points stay connected when the machine is viewed as a graph.
  ///
  /// Predicate actions also draw a visual edge to their spawned sub-parse
  /// entry states so lookahead rules do not appear disconnected.
  String toDot() {
    var buffer = StringBuffer();
    var sortedStates = [...states]..sort((a, b) => a.id.compareTo(b.id));
    var predicateClusters = _predicateClusters(sortedStates);
    var hiddenStates = _predicateWrapperStates();
    var predicateClustersByRule = {for (final cluster in predicateClusters) cluster.rule: cluster};

    var callTargets = <Rule, Set<State>>{};
    for (var state in sortedStates) {
      for (var action in state.actions) {
        if (action case CallAction(:var rule, :var returnState)) {
          (callTargets[rule] ??= {}).add(returnState);
        }
      }
    }

    buffer.writeln("digraph StateMachine {");
    buffer.writeln("  rankdir=LR;");
    buffer.writeln('  node [fontname="Courier"];');
    buffer.writeln('  "__start__" [shape=point, label=""];');
    buffer.writeln('  "__accept__" [shape=doublecircle, label="accept"];');

    for (var state in sortedStates) {
      if (hiddenStates.contains(state)) {
        continue;
      }
      var isAccept = state.actions.any((action) => action is AcceptAction);
      var label = _dotEscape(_stateLabel(state));
      var shape = isAccept ? "doublecircle" : "circle";
      buffer.writeln('  "S${state.id}" [shape=$shape, label="$label"];');
    }

    buffer.writeln('  "__start__" -> "S${startState.id}" [label="start"];');

    for (var i = 0; i < predicateClusters.length; i++) {
      var cluster = predicateClusters[i];
      buffer.writeln("  subgraph cluster_predicate_$i {");
      buffer.writeln('    style="rounded,dashed";');
      buffer.writeln('    color="gray70";');
      buffer.writeln('    label="${_dotEscape(cluster.label)}";');
      for (var state in cluster.states) {
        buffer.writeln('    "S${state.id}";');
      }
      buffer.writeln("  }");
    }

    for (var state in sortedStates) {
      for (var action in state.actions) {
        switch (action) {
          case TokenAction(:var pattern, :var nextState):
            _writeEdge(buffer, from: state, to: nextState, label: _patternEdgeLabel(pattern));
          case BoundaryAction(:var kind, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: kind == BoundaryKind.start ? "start" : "eof",
            );
          case MarkAction(:var name, :var nextState):
            _writeEdge(buffer, from: state, to: nextState, label: "mark $name");
          case LabelStartAction(:var name, :var nextState):
            _writeEdge(buffer, from: state, to: nextState, label: "label+ $name");
          case LabelEndAction(:var name, :var nextState):
            _writeEdge(buffer, from: state, to: nextState, label: "label- $name");
          case ParameterStringAction(:var codeUnit, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: "param '${String.fromCharCode(codeUnit)}'",
              style: "dashed",
              color: "slategray4",
            );
          case ParameterPredicateAction(:var isAnd, :var name, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: '${isAnd ? 'AND' : 'NOT'} param $name',
              style: "dashed",
              color: isAnd ? "seagreen4" : "firebrick3",
              constraint: false,
            );
          case PredicateAction(:var isAnd, :var symbol, :var nextState):
            var cluster = predicateClustersByRule[grammar.symbolRegistry[symbol]];
            for (var entry in ruleFirst[symbol] ?? const <State>[]) {
              _writeEdge(
                buffer,
                from: state,
                to: entry,
                label: '${isAnd ? 'AND' : 'NOT'} ${_symbolName(symbol)}',
                style: "dashed",
                color: isAnd ? "seagreen4" : "firebrick3",
                constraint: false,
              );
            }
            if (cluster != null) {
              var continuationTargets = _continuationTargets(nextState, hiddenStates);
              for (var terminal in cluster.terminalStates) {
                for (var target in continuationTargets) {
                  _writeEdge(
                    buffer,
                    from: terminal,
                    to: target,
                    label: isAnd ? "AND" : "NOT",
                    style: "dashed",
                    color: isAnd ? "seagreen4" : "firebrick3",
                    constraint: false,
                  );
                }
              }
            }
          case TailCallAction(:var rule):
            for (var entry in ruleFirst[rule.symbolId!] ?? const <State>[]) {
              var label = "tail ${rule.name.symbol}";
              if (action.pattern case RuleCall()) {
                label = "tail ${_describeRuleCall(action.pattern as RuleCall)}";
              }
              _writeEdge(buffer, from: state, to: entry, label: label, style: "dotted");
            }
          case CallAction(:var rule, :var minPrecedenceLevel):
            for (var entry in ruleFirst[rule.symbolId!] ?? const <State>[]) {
              var label = minPrecedenceLevel == null
                  ? "call ${rule.name.symbol}"
                  : "call ${rule.name.symbol}^$minPrecedenceLevel";
              if (action.pattern case RuleCall()) {
                label = "call ${_describeRuleCall(action.pattern as RuleCall, minPrecedenceLevel)}";
              }
              _writeEdge(buffer, from: state, to: entry, label: label, style: "bold");
            }
          case ReturnAction(:var rule, :var precedenceLevel):
            for (var target in callTargets[rule] ?? const <State>{}) {
              _writeEdge(
                buffer,
                from: state,
                to: target,
                label: precedenceLevel == null
                    ? "return ${rule.name.symbol}"
                    : "return ${rule.name.symbol}^$precedenceLevel",
                style: "dashed",
                color: "gray45",
              );
            }
          case ConjunctionAction(:var leftSymbol, :var rightSymbol, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: "conj $leftSymbol & $rightSymbol",
              style: "dashed",
              color: "blue",
            );
          case NegationAction(:var symbol, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: "neg ${_symbolName(symbol)}",
              style: "dashed",
              color: "orange",
            );
          case ParameterAction(:var name, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: "param $name",
              style: "dashed",
              color: "gray45",
            );
          case ParameterCallAction(:var pattern, :var nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: "paramcall $pattern",
              style: "dashed",
              color: "slategray4",
            );
          case AcceptAction():
            _writeEdge(buffer, from: state, label: "accept");
        }
      }
    }

    buffer.writeln("}");
    return buffer.toString();
  }

  String _stateLabel(State state) {
    for (var entry in _stateMapping.entries) {
      if (identical(entry.value, state)) {
        var key = entry.key;
        return switch (key) {
          InitStateKey() => "init",
          PatternStateKey(:var pattern) => pattern.toString(),
          ParamPredicateEndStateKey(:var text) => "param-predicate-end($text)",
          ParamPredicateStateKey(:var text, :var index) => "param-predicate($text:$index)",
          ParamStringStateKey(:var text, :var index) => "param-string($text:$index)",
        };
      }
    }
    return "state ${state.id}";
  }

  String _patternEdgeLabel(Pattern pattern) {
    return switch (pattern) {
      Token(:var choice) => switch (choice) {
        AnyToken() => "token any",
        ExactToken(:var value) => "token ${String.fromCharCode(value)}",
        RangeToken(:var start, :var end) => "token [$start-$end]",
        LessToken(:var bound) => "token <= $bound",
        GreaterToken(:var bound) => "token >= $bound",
      },
      StartAnchor() => "start",
      EofAnchor() => "eof",
      Marker(:var name) => "mark $name",
      Conj() => "conj",
      RuleCall() => _describeRuleCall(pattern),
      LabelStart(:var name) => "label+ $name",
      LabelEnd(:var name) => "label- $name",
      ParameterRefPattern(:var name) => "param $name",
      ParameterCallPattern(:var name) => "paramcall $name",
      And(:var pattern) => "& ${_patternSummary(pattern)}",
      Not(:var pattern) => "! ${_patternSummary(pattern)}",
      Neg(:var pattern) => "¬ ${_patternSummary(pattern)}",
      _ => pattern.toString(),
    };
  }

  String _patternSummary(Pattern pattern) {
    return switch (pattern) {
      RuleCall(:var rule) => rule.name.symbol,
      ParameterRefPattern(:var name) => name,
      ParameterCallPattern(:var name) => name,
      _ => pattern.toString(),
    };
  }

  String _symbolName(PatternSymbol symbol) {
    var pattern = grammar.symbolRegistry[symbol];
    if (pattern == null) {
      return symbol.symbol;
    }
    return pattern.toString();
  }

  String _dotEscape(String value) {
    var out = StringBuffer();
    for (var rune in value.runes) {
      switch (rune) {
        case 0x5C: // \
          out.write(r"\\");
        case 0x22: // "
          out.write(r'\"');
        case 0x0A: // newline
          out.write(r"\n");
        case 0x0D: // carriage return
          out.write(r"\r");
        case 0x09: // tab
          out.write(r"\t");
        default:
          out.write(String.fromCharCode(rune));
      }
    }
    return out.toString();
  }

  void _writeEdge(
    StringBuffer buffer, {
    required State from,
    required String label,
    State? to,
    String? style,
    String? color,
    bool? constraint,
  }) {
    if (to == null) {
      buffer.writeln('  "S${from.id}" -> "__accept__" [label="${_dotEscape(label)}"];');
      return;
    }

    var attrs = <String>['label="${_dotEscape(label)}"'];
    if (style != null) {
      attrs.add("style=$style");
    }
    if (color != null) {
      attrs.add("color=$color");
    }
    if (constraint != null) {
      attrs.add("constraint=$constraint");
    }
    buffer.writeln('  "S${from.id}" -> "S${to.id}" [${attrs.join(', ')}];');
  }

  List<_PredicateCluster> _predicateClusters(List<State> sortedStates) {
    var clusters = <_PredicateCluster>[];
    var seenRules = <Rule>{};

    for (var entry in _stateMapping.entries) {
      var key = entry.key;
      if (key is! PatternStateKey || key.pattern is! Rule) {
        continue;
      }
      var rule = key.pattern as Rule;
      if (!rule.name.symbol.startsWith(r"pred$")) {
        continue;
      }
      if (!seenRules.add(rule)) {
        continue;
      }

      var patterns = <Pattern>{};
      _collectPatterns(rule.body(), patterns);
      patterns.add(rule);

      var clusterStates = <State>[];
      var seenStates = <State>{};
      for (var pattern in patterns) {
        var state = _stateMapping[PatternStateKey(pattern)];
        if (state != null && seenStates.add(state)) {
          clusterStates.add(state);
        }
      }
      clusterStates.sort((a, b) => a.id.compareTo(b.id));

      if (clusterStates.isNotEmpty) {
        var terminalStates = <State>[];
        var seenTerminalStates = <State>{};
        for (var state in clusterStates) {
          var isTerminal = state.actions.any(
            (action) => action is ReturnAction && identical(action.rule, rule),
          );
          if (isTerminal && seenTerminalStates.add(state)) {
            terminalStates.add(state);
          }
        }
        terminalStates.sort((a, b) => a.id.compareTo(b.id));
        clusters.add(
          _PredicateCluster(
            rule: rule,
            label: "predicate ${rule.name.symbol}",
            states: clusterStates,
            terminalStates: terminalStates.isEmpty ? clusterStates : terminalStates,
          ),
        );
      }
    }

    clusters.sort((a, b) => a.states.first.id.compareTo(b.states.first.id));
    return clusters;
  }

  Set<State> _predicateWrapperStates() {
    var hidden = <State>{};
    for (var state in states) {
      for (var action in state.actions) {
        if (action case PredicateAction(:var nextState)) {
          hidden.add(nextState);
        }
      }
    }
    return hidden;
  }

  Set<State> _continuationTargets(State wrapperState, Set<State> hiddenStates) {
    var targets = <State>{};
    for (var action in wrapperState.actions) {
      switch (action) {
        case TokenAction(:var nextState):
          targets.add(nextState);
        case BoundaryAction(:var nextState):
          targets.add(nextState);
        case MarkAction(:var nextState):
          targets.add(nextState);
        case LabelStartAction(:var nextState):
          targets.add(nextState);
        case LabelEndAction(:var nextState):
          targets.add(nextState);
        case ParameterStringAction(:var nextState):
          targets.add(nextState);
        case ParameterCallAction(:var nextState):
          targets.add(nextState);
        case ParameterPredicateAction(:var nextState):
          targets.add(nextState);
        case PredicateAction(:var nextState):
          targets.addAll(_continuationTargets(nextState, hiddenStates));
        case ConjunctionAction(:var nextState):
          targets.add(nextState);
        case NegationAction(:var nextState):
          targets.add(nextState);
        case CallAction():
        case TailCallAction():
        case ParameterAction():
        case ReturnAction():
        case AcceptAction():
          break;
      }
    }

    return targets.where((state) => !hiddenStates.contains(state)).toSet();
  }

  void _collectPatterns(Pattern pattern, Set<Pattern> patterns) {
    if (!patterns.add(pattern)) {
      return;
    }
    switch (pattern) {
      case Seq(:var left, :var right) || Alt(:var left, :var right) || Conj(:var left, :var right):
        _collectPatterns(left, patterns);
        _collectPatterns(right, patterns);
      case And(:var pattern):
        _collectPatterns(pattern, patterns);
      case Not(:var pattern):
        _collectPatterns(pattern, patterns);
      case Neg(:var pattern):
        _collectPatterns(pattern, patterns);
      case Action(:var child):
        _collectPatterns(child, patterns);
      case Prec(:var child):
        _collectPatterns(child, patterns);
      case Opt(:var child):
        _collectPatterns(child, patterns);
      case Plus(:var child):
        _collectPatterns(child, patterns);
      case Star(:var child):
        _collectPatterns(child, patterns);
      case Label(:var child):
        _collectPatterns(child, patterns);
      case Rule():
      case RuleCall():
      case ParameterRefPattern():
      case ParameterCallPattern():
      case Token():
      case Marker():
      case StartAnchor():
      case EofAnchor():
      case Eps():
      case LabelStart():
      case LabelEnd():
        break;
    }
  }

  Set<RuleCall> _findDirectTailSelfCalls(Rule rule) {
    var branches = _flattenAlternation(_stripTransparent(rule.body()));
    // Only optimize the simple shape:
    //   base | prefix self
    // Anything more complex stays on the general call/return path.
    if (branches.length != 2) {
      return const <RuleCall>{};
    }

    Pattern? baseBranch;
    Pattern? recursiveBranch;
    for (var branch in branches) {
      // Exactly one branch must recurse back to the same rule.
      // Multiple recursive branches need the full generalized machinery.
      if (_containsRuleReference(branch, rule)) {
        if (recursiveBranch != null) {
          return const <RuleCall>{};
        }
        recursiveBranch = _stripTransparent(branch);
      } else {
        if (baseBranch != null) {
          return const <RuleCall>{};
        }
        baseBranch = _stripTransparent(branch);
      }
    }

    if (baseBranch == null || recursiveBranch == null) {
      return const <RuleCall>{};
    }
    // The non-recursive exit must consume input. If it can match empty, then
    // replacing recursion with a loop would erase real epsilon cycles.
    if (!_isDefinitelyNonEmpty(baseBranch)) {
      return const <RuleCall>{};
    }

    var recursiveParts = _stripDeadSuffixes(_flattenSequence(recursiveBranch));
    if (recursiveParts.isEmpty) {
      return const <RuleCall>{};
    }

    var last = _stripTransparent(recursiveParts.last);
    // Only direct right-tail self calls qualify.
    // Left recursion and precedence-constrained calls are intentionally excluded.
    if (last is! RuleCall ||
        !identical(last.rule, rule) ||
        last.minPrecedenceLevel != null ||
        last.arguments.isNotEmpty) {
      return const <RuleCall>{};
    }

    var prefixParts = recursiveParts
        .sublist(0, recursiveParts.length - 1)
        .map(_stripTransparent)
        .toList();
    // The prefix before the tail call must always make progress and must not
    // recurse. That guarantees each loop iteration advances the input.
    if (prefixParts.isEmpty || prefixParts.any((part) => _containsRuleReference(part, rule))) {
      return const <RuleCall>{};
    }

    var prefix = _joinSequence(prefixParts);
    if (!_isDefinitelyNonEmpty(prefix)) {
      return const <RuleCall>{};
    }

    return {last};
  }

  List<Pattern> _flattenAlternation(Pattern pattern) {
    return switch (pattern) {
      Alt(:var left, :var right) => [..._flattenAlternation(left), ..._flattenAlternation(right)],
      _ => [pattern],
    };
  }

  List<Pattern> _flattenSequence(Pattern pattern) {
    return switch (pattern) {
      Seq(:var left, :var right) => [..._flattenSequence(left), ..._flattenSequence(right)],
      _ => [pattern],
    };
  }

  List<Pattern> _stripDeadSuffixes(List<Pattern> patterns) {
    var end = patterns.length;
    while (end > 0 && _isDeadSuffix(patterns[end - 1])) {
      end--;
    }
    return patterns.sublist(0, end);
  }

  Pattern _stripTransparent(Pattern pattern) {
    Pattern current = pattern;
    while (true) {
      switch (current) {
        case Action(:var child):
          current = child;
        case Prec(:var child):
          current = child;
        default:
          return current;
      }
    }
  }

  bool _isDeadSuffix(Pattern pattern) {
    var stripped = _stripTransparent(pattern);
    // A trailing epsilon contributes neither input progress nor a real
    // continuation boundary, so it should not block tail-position detection.
    return stripped is Eps;
  }

  bool _containsRuleReference(Pattern pattern, Rule target) {
    var referencedRules = <Rule>{};
    pattern.collectRules(referencedRules);
    return referencedRules.contains(target);
  }

  Pattern _joinSequence(List<Pattern> patterns) {
    assert(
      patterns.isNotEmpty,
      "Invariant violation: sequence join requires at least one pattern.",
    );
    return patterns.reduce((left, right) => left >> right);
  }

  bool _isDefinitelyNonEmpty(Pattern pattern) {
    return switch (pattern) {
      Eps() || Opt() || Star() => false,
      Token() ||
      Marker() ||
      StartAnchor() ||
      EofAnchor() ||
      LabelStart() ||
      LabelEnd() ||
      Rule() ||
      RuleCall() => true,
      ParameterRefPattern() => false,
      ParameterCallPattern() => false,
      Alt(:var left, :var right) => _isDefinitelyNonEmpty(left) && _isDefinitelyNonEmpty(right),
      Seq(:var left, :var right) => _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      Conj(:var left, :var right) => _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      And() || Not() || Neg() => false,
      Action(:var child) ||
      Prec(:var child) ||
      Plus(:var child) ||
      Label(:var child) => _isDefinitelyNonEmpty(child),
    };
  }
}
