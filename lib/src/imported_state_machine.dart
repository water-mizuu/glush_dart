/// Runtime support for imported (exported) state machines
library glush.imported_state_machine;

import 'package:glush/src/grammar.dart';

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

    // Create rule placeholders (shell rules)
    final ruleMap = <String, Rule>{};
    for (final entry in spec.rules.entries) {
      final ruleName = entry.key;
      final ruleSpec = entry.value;
      final rule = Rule(ruleName, () => throw UnsupportedError('shell rule has no body'));
      rule.assignSymbolId(PatternSymbol(ruleSpec.symbolId));
      ruleMap[ruleName] = rule;
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
    final ruleFirst = <PatternSymbol, List<State>>{};
    for (final entry in spec.rules.entries) {
      final ruleName = entry.key;
      final ruleSpec = entry.value;
      final ruleSymbol = ruleMap[ruleName]!.symbolId!;
      ruleFirst[ruleSymbol] = ruleSpec.firstStateIds.map((id) => stateMap[id]!).toList();
    }

    final startRuleName = spec.rules.keys.first; // Guessing start rule if not explicit
    final startRule = ruleMap[startRuleName]!;

    // Create a shell grammar
    final shellGrammar = ShellGrammar(
      startSymbol: spec.startSymbol,
      childrenRegistry: spec.childrenRegistry,
      rules: ruleMap.values.toList(),
      startCall: startRule.call(),
    );

    // Populate symbolRegistry for rule calls in the grammar
    for (final rule in ruleMap.values) {
      // Direct rule symbol
      shellGrammar.symbolRegistry[rule.symbolId!] = rule;

      // Add a RuleCall for each rule so they can be resolved if referenced by symbol.
      // We calculate the RuleCall symbol string to match the mid-part of the rule symbol.
      final rc = RuleCall('call_${rule.name}', rule);
      final ruleMid = (rule.symbolId as String).split(":")[1];
      final ruleCallSymbol = PatternSymbol('rca:$ruleMid:');
      rc.assignSymbolId(ruleCallSymbol);
      shellGrammar.symbolRegistry[ruleCallSymbol] = rc;
    }

    // Create the rebuilt state machine
    final sm = StateMachine.empty(shellGrammar);

    // Manually set the internal state
    sm.rules.addAll(ruleMap.values.map((r) => r.symbolId!));
    for (final entry in ruleFirst.entries) {
      final rule = entry.key;
      final states = entry.value;
      sm.ruleFirst[rule] = states;
    }

    // Initialize with initial states and state mapping
    sm.initializeImported(spec.initialStateIds.map((id) => stateMap[id]!).toList(), stateMap);

    return sm;
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
      CallActionSpec(:var ruleName, :var nextStateId, :var minPrecedenceLevel) => CallAction(
        ruleMap[ruleName]!,
        // Create a dummy RuleCall - won't be used since we have state transitions
        RuleCall('${ruleName}_call', ruleMap[ruleName]!),
        stateMap[nextStateId]!,
        minPrecedenceLevel,
      ),
      ReturnActionSpec(:var ruleName, :var precedenceLevel) => ReturnAction(
        ruleMap[ruleName]!,
        Eps(),
        precedenceLevel,
      ),
      AcceptActionSpec() => const AcceptAction(),
      PredicateActionSpec(:var isAnd, :var nextStateId, :var symbol) => PredicateAction(
        isAnd: isAnd,
        symbol: symbol,
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
}
