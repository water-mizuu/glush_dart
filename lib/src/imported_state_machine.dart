/// Runtime support for imported (exported) state machines
library glush.imported_state_machine;

import 'patterns.dart';
import 'state_machine.dart';
import 'state_machine_export.dart';
import 'sm_parser.dart';

/// Reconstructs and manages an imported (exported) state machine
/// Allows reattaching semantic actions at runtime
class ImportedStateMachine {
  final ExportedStateMachine spec;
  final Map<String, Function?> _actionCallbacks = {};
  late final StateMachine _rebuilt;

  ImportedStateMachine(this.spec) {
    _rebuilt = _rebuildStateMachine();
  }

  /// Attach a semantic action callback by actionId
  void attachAction(String actionId, Function callback) {
    _actionCallbacks[actionId] = callback;
  }

  /// Create an SMParser that uses this imported state machine
  SMParser createParser() {
    return SMParser.fromStateMachine(_rebuilt);
  }

  /// Call an attached action by ID, or return null if not attached
  Object? callAction(String actionId, String span, List<Object?> results) {
    final callback = _actionCallbacks[actionId];
    if (callback == null) {
      return null;
    }
    return Function.apply(callback, [span, results]);
  }

  // ========================================================================
  // RECONSTRUCTION LOGIC
  // ========================================================================

  StateMachine _rebuildStateMachine() {
    // Create State objects for each state spec
    final stateMap = <int, State>{};
    for (final stateSpec in spec.states) {
      stateMap[stateSpec.id] = State(stateSpec.id);
    }

    // Create rule placeholders with lazy pattern deserialization
    final ruleMap = <String, Rule>{};
    final patternCache = <String, Pattern>{};

    for (final ruleName in spec.rules.keys) {
      // Create a rule with a factory that deserializes the pattern on demand
      ruleMap[ruleName] = Rule(ruleName, () {
        // Check cache first
        if (patternCache.containsKey(ruleName)) {
          return patternCache[ruleName]!;
        }

        // Deserialize pattern from the exported spec
        final ruleSpec = spec.rules[ruleName]!;
        final pattern = ruleSpec.patternSpec != null
            ? _specToPattern(ruleSpec.patternSpec!, ruleMap)
            : Eps(); // Fallback to Eps if no pattern spec

        // Restore symbol IDs
        final symbolId = ruleSpec.patternSpec?.getSymbolId();
        if (symbolId != null) {
          pattern.assignSymbolId(symbolId);
        }

        patternCache[ruleName] = pattern;
        return pattern;
      });
    }

    // Reconstruct state actions
    for (final stateSpec in spec.states) {
      final state = stateMap[stateSpec.id]!;
      for (final actionSpec in stateSpec.actions) {
        final action = _reconstructAction(actionSpec, stateMap, ruleMap);
        state.actions.add(action);
      }
    }

    // Build ruleFirst mapping
    final ruleFirst = <Rule, List<State>>{};
    for (final entry in spec.rules.entries) {
      final ruleName = entry.key;
      final ruleSpec = entry.value;
      final rule = ruleMap[ruleName]!;
      ruleFirst[rule] = ruleSpec.firstStateIds.map((id) => stateMap[id]!).toList();
    }

    // Create an adapter that provides the GrammarInterface
    final adapter = _GrammarAdapter._withRules(
      ruleMap.values.toList(),
      ruleMap.values.first.call(),
    );

    // Create the rebuilt state machine
    final sm = StateMachine.empty(adapter);

    // Manually set the internal state
    sm.rules.addAll(ruleMap.values);
    for (final entry in ruleFirst.entries) {
      final rule = entry.key;
      final states = entry.value;
      sm.ruleFirst[rule] = states;
    }

    // Initialize with initial states and state mapping
    sm.initializeImported(spec.initialStateIds.map((id) => stateMap[id]!).toList(), stateMap);

    // Assign symbol IDs to all patterns for enumeration support
    _assignSymbolIds(sm);

    return sm;
  }

  /// Assign symbol IDs to patterns in the rebuilt state machine
  void _assignSymbolIds(StateMachine sm) {
    int counter = 0;

    // Assign IDs to all rules
    for (final rule in sm.rules) {
      if (rule.symbolId == null) {
        rule.assignSymbolId('S${counter++}');
      }
      // Also assign IDs to patterns in the rule body
      _assignSymbolIdsToPattern(rule.body(), (id) {
        final symbolId = 'S${counter++}';
        return symbolId;
      }, <String>{});
    }
  }

  /// Recursively assign symbol IDs to patterns
  void _assignSymbolIdsToPattern(
    Pattern pattern,
    String Function(int) idGenerator,
    Set<String> assigned,
  ) {
    if (pattern.symbolId != null && assigned.contains(pattern.symbolId!)) {
      return; // Already assigned
    }

    if (pattern is! Rule && pattern.symbolId == null) {
      pattern.assignSymbolId(idGenerator(0)); // counter is ignored in idGenerator
    }

    if (pattern is Seq) {
      _assignSymbolIdsToPattern(pattern.left, idGenerator, assigned);
      _assignSymbolIdsToPattern(pattern.right, idGenerator, assigned);
    } else if (pattern is Alt) {
      _assignSymbolIdsToPattern(pattern.left, idGenerator, assigned);
      _assignSymbolIdsToPattern(pattern.right, idGenerator, assigned);
    } else if (pattern is Plus) {
      _assignSymbolIdsToPattern(pattern.child, idGenerator, assigned);
    } else if (pattern is Star) {
      _assignSymbolIdsToPattern(pattern.child, idGenerator, assigned);
    } else if (pattern is And) {
      _assignSymbolIdsToPattern(pattern.pattern, idGenerator, assigned);
    } else if (pattern is Not) {
      _assignSymbolIdsToPattern(pattern.pattern, idGenerator, assigned);
    } else if (pattern is Action) {
      _assignSymbolIdsToPattern(pattern.child, idGenerator, assigned);
    } else if (pattern is Conj) {
      _assignSymbolIdsToPattern(pattern.left, idGenerator, assigned);
      _assignSymbolIdsToPattern(pattern.right, idGenerator, assigned);
    }
  }

  StateAction _reconstructAction(
    StateActionSpec spec,
    Map<int, State> stateMap,
    Map<String, Rule> ruleMap,
  ) {
    return switch (spec) {
      TokenActionSpec(:var tokenSpec, :var nextStateId) => TokenAction(
        _tokenSpecToPattern(tokenSpec),
        stateMap[nextStateId]!,
      ),
      MarkActionSpec(:var name, :var nextStateId) => MarkAction(
        name,
        Marker(name),
        stateMap[nextStateId]!,
      ),
      CallActionSpec(:var ruleName, :var nextStateId) => CallAction(
        ruleMap[ruleName]!,
        RuleCall('${ruleName}_call', ruleMap[ruleName]!),
        stateMap[nextStateId]!,
      ),
      ReturnActionSpec(:var ruleName) => ReturnAction(ruleMap[ruleName]!, Eps()),
      AcceptActionSpec() => const AcceptAction(),
      PredicateActionSpec(:var isAnd, :var nextStateId) => PredicateAction(
        isAnd: isAnd,
        pattern: Eps(),
        nextState: stateMap[nextStateId]!,
      ),
      SemanticActionCallSpec(:var actionId, :var nextStateId) => SemanticAction(
        (span, results) => callAction(actionId, span, results),
        stateMap[nextStateId]!,
      ),
    };
  }

  Pattern _tokenSpecToPattern(TokenSpec tokenSpec) {
    final choice = switch (tokenSpec) {
      AnyTokenSpec() => const AnyToken(),
      ExactTokenSpec(:var value) => ExactToken(value),
      RangeTokenSpec(:var start, :var end) => RangeToken(start, end),
    };
    return Token(choice);
  }

  /// Reconstruct a pattern from rule and state machine structure
  /// Convert a PatternSpec back into a Pattern object
  Pattern _specToPattern(PatternSpec spec, Map<String, Rule> ruleMap) {
    return switch (spec) {
      TokenPatternSpec(:var tokenSpec) => Token(_tokenSpecToChoice(tokenSpec)),
      EpsPatternSpec() => Eps(),
      MarkerPatternSpec(:var name) => Marker(name),
      AltPatternSpec(:var left, :var right) => Alt(
        _specToPattern(left, ruleMap),
        _specToPattern(right, ruleMap),
      ),
      SeqPatternSpec(:var left, :var right) => Seq(
        _specToPattern(left, ruleMap),
        _specToPattern(right, ruleMap),
      ),
      ConjPatternSpec(:var left, :var right) => Conj(
        _specToPattern(left, ruleMap),
        _specToPattern(right, ruleMap),
      ),
      PlusPatternSpec(:var child) => Plus(_specToPattern(child, ruleMap)),
      StarPatternSpec(:var child) => Star(_specToPattern(child, ruleMap)),
      AndPatternSpec(:var pattern) => And(_specToPattern(pattern, ruleMap)),
      NotPatternSpec(:var pattern) => Not(_specToPattern(pattern, ruleMap)),
      RuleCallPatternSpec(:var ruleName) => RuleCall(ruleName, ruleMap[ruleName]!),
      CallPatternSpec(:var ruleName, :var minPrecedenceLevel) => Call(
        ruleMap[ruleName]!,
        minPrecedenceLevel: minPrecedenceLevel,
      ),
      PrecedenceLabeledPatternSpec(:var precedenceLevel, :var pattern) => PrecedenceLabeledPattern(
        precedenceLevel,
        _specToPattern(pattern, ruleMap),
      ),
      ActionPatternSpec(:var child) => Action<dynamic>(
        _specToPattern(child, ruleMap),
        (span, results) => results,
      ),
    };
  }

  /// Convert a TokenSpec to a TokenChoice
  TokenChoice _tokenSpecToChoice(TokenSpec spec) {
    return switch (spec) {
      AnyTokenSpec() => AnyToken(),
      ExactTokenSpec(:var value) => ExactToken(value),
      RangeTokenSpec(:var start, :var end) => RangeToken(start, end),
    };
  }
}

// ============================================================================
// GRAMMAR ADAPTER FOR IMPORTED MACHINES
// ============================================================================

/// Provides GrammarInterface for imported state machines
class _GrammarAdapter implements GrammarInterface {
  @override
  final List<Rule> rules;

  @override
  final RuleCall startCall;

  @override
  final Map<String, Pattern> symbolRegistry = {};

  _GrammarAdapter(StateMachine sm)
    : rules = sm.rules,
      startCall = sm.rules.isNotEmpty ? sm.rules[0].call() : Rule('_dummy', () => Eps()).call();

  _GrammarAdapter._withRules(this.rules, this.startCall);

  @override
  bool isEmpty() => rules.isEmpty;
}
