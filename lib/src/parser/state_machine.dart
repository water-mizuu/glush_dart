/// State machine compilation from grammars
library glush.state_machine;

import 'package:glush/src/core/grammar.dart';

import '../core/patterns.dart';

// Action types for state machine
sealed class StateAction {
  const StateAction();
}

final class MarkAction implements StateAction {
  final String name;
  final Pattern pattern;
  final State nextState;

  const MarkAction(this.name, this.pattern, this.nextState);
}

final class TokenAction implements StateAction {
  final Pattern pattern;
  final State nextState;

  const TokenAction(this.pattern, this.nextState);
}

enum BoundaryKind { start, eof }

final class BoundaryAction implements StateAction {
  final BoundaryKind kind;
  final Pattern pattern;
  final State nextState;

  const BoundaryAction(this.kind, this.pattern, this.nextState);
}

final class LabelStartAction implements StateAction {
  final String name;
  final Pattern pattern;
  final State nextState;

  const LabelStartAction(this.name, this.pattern, this.nextState);
}

final class LabelEndAction implements StateAction {
  final String name;
  final Pattern pattern;
  final State nextState;

  const LabelEndAction(this.name, this.pattern, this.nextState);
}

final class CallAction implements StateAction {
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

final class TailCallAction implements StateAction {
  final Rule rule;
  final Pattern pattern;
  final int? minPrecedenceLevel;

  const TailCallAction(this.rule, this.pattern, [this.minPrecedenceLevel]);

  @override
  String toString() => minPrecedenceLevel != null
      ? 'TailCallAction(${rule.name}^$minPrecedenceLevel)'
      : 'TailCallAction(${rule.name})';
}

final class ReturnAction implements StateAction {
  final Rule rule;
  final Pattern lastPattern;
  final int? precedenceLevel;

  const ReturnAction(this.rule, this.lastPattern, [this.precedenceLevel]);

  @override
  String toString() => precedenceLevel != null
      ? 'ReturnAction(${rule.name}, prec: $precedenceLevel)'
      : 'ReturnAction(${rule.name})';
}

final class AcceptAction implements StateAction {
  const AcceptAction();
}

/// Predicate action for lookahead assertions (AND/NOT predicates)
/// Does not consume input - purely a condition check
final class PredicateAction implements StateAction {
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

final class _PredicateCluster {
  final Rule rule;
  final String label;
  final List<State> states;
  final List<State> terminalStates;

  const _PredicateCluster({
    required this.rule,
    required this.label,
    required this.states,
    required this.terminalStates,
  });
}

/// The compiled state machine
class StateMachine {
  final GrammarInterface grammar;
  final List<PatternSymbol> rules = [];
  final Map<PatternSymbol, List<State>> ruleFirst = {};
  List<State>? _cachedStates;
  late final List<State> _initialStates;

  final Map<Object, State> _stateMapping = {};
  final Map<Rule, Set<RuleCall>> _tailSelfCalls = {};

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
      assert(
        rule.symbolId != null,
        'Invariant violation in StateMachine: rule.symbolId must be assigned before compilation.',
      );
      rules.add(rule.symbolId!);

      final firstState = _getOrCreateState(rule);
      ruleFirst[rule.symbolId!] = [firstState];
      _tailSelfCalls[rule] = _findDirectTailSelfCalls(rule);

      // Pre-calculate precedence mapping for this rule's body
      final precMap = <Pattern, int?>{};
      _buildPrecedenceMap(rule.body(), null, precMap);

      // Connect to first patterns
      for (final firstStateInRange in rule.body().firstSet()) {
        _connect(firstState, firstStateInRange, currentRule: rule);
      }

      // Connect each pair
      rule.body().eachPair((a, b) {
        _connect(_getOrCreateState(a), b, currentRule: rule);
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

  void _connect(State state, Pattern terminal, {Rule? currentRule}) {
    switch (terminal) {
      case Token() || Conj():
        final nextState = _getOrCreateState(terminal);
        final action = TokenAction(terminal, nextState);
        state.actions.add(action);
      case StartAnchor() || EofAnchor():
        final nextState = _getOrCreateState(terminal);
        final action = BoundaryAction(
          terminal is StartAnchor ? BoundaryKind.start : BoundaryKind.eof,
          terminal,
          nextState,
        );
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
        final minPrecedenceLevel = terminal.minPrecedenceLevel;
        // Compile a direct tail self-call as a loop instead of a real GSS call.
        // This is only safe when the compiler has already proven that the call
        // sits at the far right edge of the recursive branch and the prefix
        // before it always consumes input.
        if (currentRule != null &&
            minPrecedenceLevel == null &&
            (_tailSelfCalls[currentRule]?.contains(terminal) ?? false)) {
          state.actions.add(TailCallAction(rule, terminal, minPrecedenceLevel));
        } else {
          final returnState = _getOrCreateState(terminal);
          final callAction = CallAction(rule, terminal, returnState, minPrecedenceLevel);
          state.actions.add(callAction);
        }
      case LabelStart():
        final nextState = _getOrCreateState(terminal);
        final labelStartAction = LabelStartAction(terminal.name, terminal, nextState);
        state.actions.add(labelStartAction);
      case LabelEnd():
        final nextState = _getOrCreateState(terminal);
        final labelEndAction = LabelEndAction(terminal.name, terminal, nextState);
        state.actions.add(labelEndAction);
      case Eps():
        // Epsilon doesn't create transitions
        break;
      case Action() || Alt() || Seq() || Rule() || Prec() || Label() || Opt() || Plus() || Star():
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
    } else if (pattern is Label) {
      _buildPrecedenceMap(pattern.child, current, map);
      map[pattern] = current;
      assert(
        pattern.firstSet().isNotEmpty && pattern.lastSet().isNotEmpty,
        'Invariant violation in _buildPrecedenceMap: Label must expose non-empty '
        'first/last sets for precedence propagation.',
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
    final buffer = StringBuffer();
    final sortedStates = [...states]..sort((a, b) => a.id.compareTo(b.id));
    final predicateClusters = _predicateClusters(sortedStates);
    final hiddenStates = _predicateWrapperStates();
    final predicateClustersByRule = {
      for (final cluster in predicateClusters) cluster.rule: cluster,
    };

    final callTargets = <Rule, Set<State>>{};
    for (final state in sortedStates) {
      for (final action in state.actions) {
        if (action case CallAction(:final rule, :final returnState)) {
          callTargets.putIfAbsent(rule, () => <State>{}).add(returnState);
        }
      }
    }

    buffer.writeln('digraph StateMachine {');
    buffer.writeln('  rankdir=LR;');
    buffer.writeln('  node [fontname="Courier"];');
    buffer.writeln('  "__start__" [shape=point, label=""];');
    buffer.writeln('  "__accept__" [shape=doublecircle, label="accept"];');

    for (final state in sortedStates) {
      if (hiddenStates.contains(state)) {
        continue;
      }
      final isAccept = state.actions.any((action) => action is AcceptAction);
      final label = _dotEscape(_stateLabel(state));
      final shape = isAccept ? 'doublecircle' : 'circle';
      buffer.writeln('  "S${state.id}" [shape=$shape, label="$label"];');
    }

    buffer.writeln('  "__start__" -> "S${startState.id}" [label="start"];');

    for (var i = 0; i < predicateClusters.length; i++) {
      final cluster = predicateClusters[i];
      buffer.writeln('  subgraph cluster_predicate_$i {');
      buffer.writeln('    style="rounded,dashed";');
      buffer.writeln('    color="gray70";');
      buffer.writeln('    label="${_dotEscape(cluster.label)}";');
      for (final state in cluster.states) {
        buffer.writeln('    "S${state.id}";');
      }
      buffer.writeln('  }');
    }

    for (final state in sortedStates) {
      for (final action in state.actions) {
        switch (action) {
          case TokenAction(:final pattern, :final nextState):
            _writeEdge(buffer, from: state, to: nextState, label: _patternEdgeLabel(pattern));
          case BoundaryAction(:final kind, :final nextState):
            _writeEdge(
              buffer,
              from: state,
              to: nextState,
              label: kind == BoundaryKind.start ? 'start' : 'eof',
            );
          case MarkAction(:final name, :final nextState):
            _writeEdge(buffer, from: state, to: nextState, label: 'mark $name');
          case LabelStartAction(:final name, :final nextState):
            _writeEdge(buffer, from: state, to: nextState, label: 'label+ $name');
          case LabelEndAction(:final name, :final nextState):
            _writeEdge(buffer, from: state, to: nextState, label: 'label- $name');
          case PredicateAction(:final isAnd, :final symbol, :final nextState):
            final cluster = predicateClustersByRule[grammar.symbolRegistry[symbol]];
            for (final entry in ruleFirst[symbol] ?? const <State>[]) {
              _writeEdge(
                buffer,
                from: state,
                to: entry,
                label: '${isAnd ? 'AND' : 'NOT'} ${_symbolName(symbol)}',
                style: 'dashed',
                color: isAnd ? 'seagreen4' : 'firebrick3',
                constraint: false,
              );
            }
            if (cluster != null) {
              final continuationTargets = _continuationTargets(nextState, hiddenStates);
              for (final terminal in cluster.terminalStates) {
                for (final target in continuationTargets) {
                  _writeEdge(
                    buffer,
                    from: terminal,
                    to: target,
                    label: isAnd ? 'AND' : 'NOT',
                    style: 'dashed',
                    color: isAnd ? 'seagreen4' : 'firebrick3',
                    constraint: false,
                  );
                }
              }
            }
          case TailCallAction(:final rule):
            for (final entry in ruleFirst[rule.symbolId!] ?? const <State>[]) {
              _writeEdge(
                buffer,
                from: state,
                to: entry,
                label: 'tail ${rule.name.symbol}',
                style: 'dotted',
              );
            }
          case CallAction(:final rule, :final minPrecedenceLevel):
            for (final entry in ruleFirst[rule.symbolId!] ?? const <State>[]) {
              _writeEdge(
                buffer,
                from: state,
                to: entry,
                label: minPrecedenceLevel == null
                    ? 'call ${rule.name.symbol}'
                    : 'call ${rule.name.symbol}^$minPrecedenceLevel',
                style: 'bold',
              );
            }
          case ReturnAction(:final rule, :final precedenceLevel):
            for (final target in callTargets[rule] ?? const <State>{}) {
              _writeEdge(
                buffer,
                from: state,
                to: target,
                label: precedenceLevel == null
                    ? 'return ${rule.name.symbol}'
                    : 'return ${rule.name.symbol}^$precedenceLevel',
                style: 'dashed',
                color: 'gray45',
              );
            }
          case AcceptAction():
            _writeEdge(buffer, from: state, to: null, label: 'accept');
        }
      }
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  String _stateLabel(State state) {
    for (final entry in _stateMapping.entries) {
      if (identical(entry.value, state)) {
        final key = entry.key;
        return switch (key) {
          ':init' => 'init',
          Pattern pattern => pattern.toString(),
          _ => key.toString(),
        };
      }
    }
    return 'state ${state.id}';
  }

  String _patternEdgeLabel(Pattern pattern) {
    return switch (pattern) {
      Token(:final choice) => switch (choice) {
        AnyToken() => 'token any',
        ExactToken(:final value) => 'token ${String.fromCharCode(value)}',
        RangeToken(:final start, :final end) => 'token [$start-$end]',
        LessToken(:final bound) => 'token <= $bound',
        GreaterToken(:final bound) => 'token >= $bound',
      },
      StartAnchor() => 'start',
      EofAnchor() => 'eof',
      Marker(:final name) => 'mark $name',
      Conj() => 'conj',
      RuleCall(:final rule, :final minPrecedenceLevel) =>
        minPrecedenceLevel == null
            ? 'call ${rule.name.symbol}'
            : 'call ${rule.name.symbol}^$minPrecedenceLevel',
      LabelStart(:final name) => 'label+ $name',
      LabelEnd(:final name) => 'label- $name',
      And(:final pattern) => '& ${_patternSummary(pattern)}',
      Not(:final pattern) => '! ${_patternSummary(pattern)}',
      _ => pattern.toString(),
    };
  }

  String _patternSummary(Pattern pattern) {
    return switch (pattern) {
      RuleCall(:final rule) => rule.name.symbol,
      _ => pattern.toString(),
    };
  }

  String _symbolName(PatternSymbol symbol) {
    final pattern = grammar.symbolRegistry[symbol];
    if (pattern == null) return symbol.symbol;
    return pattern.toString();
  }

  String _dotEscape(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      switch (rune) {
        case 0x5C: // \
          out.write(r'\\');
        case 0x22: // "
          out.write(r'\"');
        case 0x0A: // newline
          out.write(r'\n');
        case 0x0D: // carriage return
          out.write(r'\r');
        case 0x09: // tab
          out.write(r'\t');
        default:
          out.write(String.fromCharCode(rune));
      }
    }
    return out.toString();
  }

  void _writeEdge(
    StringBuffer buffer, {
    required State from,
    State? to,
    required String label,
    String? style,
    String? color,
    bool? constraint,
  }) {
    if (to == null) {
      buffer.writeln('  "S${from.id}" -> "__accept__" [label="${_dotEscape(label)}"];');
      return;
    }

    final attrs = <String>['label="${_dotEscape(label)}"'];
    if (style != null) {
      attrs.add('style=$style');
    }
    if (color != null) {
      attrs.add('color=$color');
    }
    if (constraint != null) {
      attrs.add('constraint=$constraint');
    }
    buffer.writeln('  "S${from.id}" -> "S${to.id}" [${attrs.join(', ')}];');
  }

  List<_PredicateCluster> _predicateClusters(List<State> sortedStates) {
    final clusters = <_PredicateCluster>[];
    final seenRules = <Rule>{};

    for (final entry in _stateMapping.entries) {
      final key = entry.key;
      if (key is! Rule) continue;
      final rule = key;
      if (!rule.name.symbol.startsWith('pred\$')) continue;
      if (!seenRules.add(rule)) continue;

      final patterns = <Pattern>{};
      _collectPatterns(rule.body(), patterns);
      patterns.add(rule);

      final clusterStates = <State>[];
      final seenStates = <State>{};
      for (final pattern in patterns) {
        final state = _stateMapping[pattern];
        if (state != null && seenStates.add(state)) {
          clusterStates.add(state);
        }
      }
      clusterStates.sort((a, b) => a.id.compareTo(b.id));

      if (clusterStates.isNotEmpty) {
        final terminalStates = <State>[];
        final seenTerminalStates = <State>{};
        for (final state in clusterStates) {
          final isTerminal = state.actions.any(
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
            label: 'predicate ${rule.name.symbol}',
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
    final hidden = <State>{};
    for (final state in states) {
      for (final action in state.actions) {
        if (action case PredicateAction(:final nextState)) {
          hidden.add(nextState);
        }
      }
    }
    return hidden;
  }

  Set<State> _continuationTargets(State wrapperState, Set<State> hiddenStates) {
    final targets = <State>{};
    for (final action in wrapperState.actions) {
      switch (action) {
        case TokenAction(:final nextState):
          targets.add(nextState);
        case BoundaryAction(:final nextState):
          targets.add(nextState);
        case MarkAction(:final nextState):
          targets.add(nextState);
        case LabelStartAction(:final nextState):
          targets.add(nextState);
        case LabelEndAction(:final nextState):
          targets.add(nextState);
        case PredicateAction(:final nextState):
          targets.addAll(_continuationTargets(nextState, hiddenStates));
        case CallAction():
        case TailCallAction():
        case ReturnAction():
        case AcceptAction():
          break;
      }
    }

    return targets.where((state) => !hiddenStates.contains(state)).toSet();
  }

  void _collectPatterns(Pattern pattern, Set<Pattern> patterns) {
    if (!patterns.add(pattern)) return;
    switch (pattern) {
      case Seq(:final left, :final right) ||
          Alt(:final left, :final right) ||
          Conj(:final left, :final right):
        _collectPatterns(left, patterns);
        _collectPatterns(right, patterns);
      case And(:final pattern):
        _collectPatterns(pattern, patterns);
      case Not(:final pattern):
        _collectPatterns(pattern, patterns);
      case Action(:final child):
        _collectPatterns(child, patterns);
      case Prec(:final child):
        _collectPatterns(child, patterns);
      case Opt(:final child):
        _collectPatterns(child, patterns);
      case Plus(:final child):
        _collectPatterns(child, patterns);
      case Star(:final child):
        _collectPatterns(child, patterns);
      case Label(:final child):
        _collectPatterns(child, patterns);
      case Rule():
      case RuleCall():
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
    final branches = _flattenAlternation(_stripTransparent(rule.body()));
    // Only optimize the simple shape:
    //   base | prefix self
    // Anything more complex stays on the general call/return path.
    if (branches.length != 2) return const <RuleCall>{};

    Pattern? baseBranch;
    Pattern? recursiveBranch;
    for (final branch in branches) {
      // Exactly one branch must recurse back to the same rule.
      // Multiple recursive branches need the full generalized machinery.
      if (_containsRuleReference(branch, rule)) {
        if (recursiveBranch != null) return const <RuleCall>{};
        recursiveBranch = _stripTransparent(branch);
      } else {
        if (baseBranch != null) return const <RuleCall>{};
        baseBranch = _stripTransparent(branch);
      }
    }

    if (baseBranch == null || recursiveBranch == null) return const <RuleCall>{};
    // The non-recursive exit must consume input. If it can match empty, then
    // replacing recursion with a loop would erase real epsilon cycles.
    if (!_isDefinitelyNonEmpty(baseBranch)) return const <RuleCall>{};

    final recursiveParts = _stripDeadSuffixes(_flattenSequence(recursiveBranch));
    if (recursiveParts.isEmpty) return const <RuleCall>{};

    final last = _stripTransparent(recursiveParts.last);
    // Only direct right-tail self calls qualify.
    // Left recursion and precedence-constrained calls are intentionally excluded.
    if (last is! RuleCall || !identical(last.rule, rule) || last.minPrecedenceLevel != null) {
      return const <RuleCall>{};
    }

    final prefixParts = recursiveParts
        .sublist(0, recursiveParts.length - 1)
        .map(_stripTransparent)
        .toList();
    // The prefix before the tail call must always make progress and must not
    // recurse. That guarantees each loop iteration advances the input.
    if (prefixParts.isEmpty || prefixParts.any((part) => _containsRuleReference(part, rule))) {
      return const <RuleCall>{};
    }

    final prefix = _joinSequence(prefixParts);
    if (!_isDefinitelyNonEmpty(prefix)) return const <RuleCall>{};

    return {last};
  }

  List<Pattern> _flattenAlternation(Pattern pattern) {
    return switch (pattern) {
      Alt(:final left, :final right) => [
        ..._flattenAlternation(left),
        ..._flattenAlternation(right),
      ],
      _ => [pattern],
    };
  }

  List<Pattern> _flattenSequence(Pattern pattern) {
    return switch (pattern) {
      Seq(:final left, :final right) => [..._flattenSequence(left), ..._flattenSequence(right)],
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
        case Action(:final child):
          current = child;
        case Prec(:final child):
          current = child;
        default:
          return current;
      }
    }
  }

  bool _isDeadSuffix(Pattern pattern) {
    final stripped = _stripTransparent(pattern);
    // A trailing epsilon contributes neither input progress nor a real
    // continuation boundary, so it should not block tail-position detection.
    return stripped is Eps;
  }

  bool _containsRuleReference(Pattern pattern, Rule target) {
    final referencedRules = <Rule>{};
    pattern.collectRules(referencedRules);
    return referencedRules.contains(target);
  }

  Pattern _joinSequence(List<Pattern> patterns) {
    assert(
      patterns.isNotEmpty,
      'Invariant violation: sequence join requires at least one pattern.',
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
      Alt(:final left, :final right) => _isDefinitelyNonEmpty(left) && _isDefinitelyNonEmpty(right),
      Seq(:final left, :final right) => _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      Conj(:final left, :final right) =>
        _isDefinitelyNonEmpty(left) || _isDefinitelyNonEmpty(right),
      And() || Not() => false,
      Action(:final child) ||
      Prec(:final child) ||
      Plus(:final child) ||
      Label(:final child) => _isDefinitelyNonEmpty(child),
    };
  }
}
