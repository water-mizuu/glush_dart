/// State machine export and serialization
library glush.state_machine_export;

import 'dart:convert';
import 'patterns.dart';
import 'state_machine.dart';

// ============================================================================
// SERIALIZABLE ACTION SPECIFICATIONS
// ============================================================================

/// Base class for serializable state action specifications
sealed class StateActionSpec {
  const StateActionSpec();

  Map<String, dynamic> toJson();
  static StateActionSpec fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'token' => TokenActionSpec.fromJson(json),
      'mark' => MarkActionSpec.fromJson(json),
      'call' => CallActionSpec.fromJson(json),
      'return' => ReturnActionSpec.fromJson(json),
      'accept' => const AcceptActionSpec(),
      'predicate' => PredicateActionSpec.fromJson(json),
      'semantic' => SemanticActionCallSpec.fromJson(json),
      _ => throw UnsupportedError('Unknown action type: $type'),
    };
  }
}

class TokenActionSpec extends StateActionSpec {
  final TokenSpec tokenSpec;
  final int nextStateId;

  const TokenActionSpec(this.tokenSpec, this.nextStateId);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'token',
    'tokenSpec': tokenSpec.toJson(),
    'nextStateId': nextStateId,
  };

  static TokenActionSpec fromJson(Map<String, dynamic> json) {
    return TokenActionSpec(
      TokenSpec.fromJson(json['tokenSpec'] as Map<String, dynamic>),
      json['nextStateId'] as int,
    );
  }
}

class MarkActionSpec extends StateActionSpec {
  final String name;
  final int nextStateId;

  const MarkActionSpec(this.name, this.nextStateId);

  @override
  Map<String, dynamic> toJson() => {'type': 'mark', 'name': name, 'nextStateId': nextStateId};

  static MarkActionSpec fromJson(Map<String, dynamic> json) {
    return MarkActionSpec(json['name'] as String, json['nextStateId'] as int);
  }
}

class CallActionSpec extends StateActionSpec {
  final String ruleName;
  final int nextStateId;
  final int? minPrecedenceLevel;

  const CallActionSpec(this.ruleName, this.nextStateId, [this.minPrecedenceLevel]);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'call',
    'ruleName': ruleName,
    'nextStateId': nextStateId,
    if (minPrecedenceLevel != null) 'minPrecedenceLevel': minPrecedenceLevel,
  };

  static CallActionSpec fromJson(Map<String, dynamic> json) {
    return CallActionSpec(
      json['ruleName'] as String,
      json['nextStateId'] as int,
      json['minPrecedenceLevel'] as int?,
    );
  }
}

class ReturnActionSpec extends StateActionSpec {
  final String ruleName;
  final int? precedenceLevel;

  const ReturnActionSpec(this.ruleName, [this.precedenceLevel]);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'return',
    'ruleName': ruleName,
    if (precedenceLevel != null) 'precedenceLevel': precedenceLevel,
  };

  static ReturnActionSpec fromJson(Map<String, dynamic> json) {
    return ReturnActionSpec(json['ruleName'] as String, json['precedenceLevel'] as int?);
  }
}

class AcceptActionSpec extends StateActionSpec {
  const AcceptActionSpec();

  @override
  Map<String, dynamic> toJson() => {'type': 'accept'};
}

class PredicateActionSpec extends StateActionSpec {
  final bool isAnd;
  final PatternSymbol symbol;
  final int nextStateId;

  const PredicateActionSpec({
    required this.isAnd, //
    required this.symbol,
    required this.nextStateId,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'predicate',
    'isAnd': isAnd,
    'symbol': symbol,
    'nextStateId': nextStateId,
  };

  static PredicateActionSpec fromJson(Map<String, dynamic> json) {
    return PredicateActionSpec(
      isAnd: json['isAnd'] as bool,
      symbol: PatternSymbol(json['symbol'] as String),
      nextStateId: json['nextStateId'] as int,
    );
  }
}

class SemanticActionCallSpec extends StateActionSpec {
  final String actionId;
  final int nextStateId;

  const SemanticActionCallSpec(this.actionId, this.nextStateId);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'semantic',
    'actionId': actionId,
    'nextStateId': nextStateId,
  };

  static SemanticActionCallSpec fromJson(Map<String, dynamic> json) {
    return SemanticActionCallSpec(json['actionId'] as String, json['nextStateId'] as int);
  }
}

// ============================================================================
// SERIALIZABLE TOKEN SPECIFICATIONS
// ============================================================================

sealed class TokenSpec {
  const TokenSpec();

  bool matches(int? codeUnit);

  Map<String, dynamic> toJson();
  static TokenSpec fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'any' => const AnyTokenSpec(),
      'exact' => ExactTokenSpec(json['value'] as int),
      'range' => RangeTokenSpec(json['start'] as int, json['end'] as int),
      _ => throw UnsupportedError('Unknown token type: $type'),
    };
  }
}

class AnyTokenSpec extends TokenSpec {
  const AnyTokenSpec();

  @override
  bool matches(int? codeUnit) => codeUnit != null;

  @override
  Map<String, dynamic> toJson() => {'type': 'any'};
}

class ExactTokenSpec extends TokenSpec {
  final int value;

  const ExactTokenSpec(this.value);

  @override
  bool matches(int? codeUnit) => codeUnit == value;

  @override
  Map<String, dynamic> toJson() => {'type': 'exact', 'value': value};
}

class RangeTokenSpec extends TokenSpec {
  final int start;
  final int end;

  const RangeTokenSpec(this.start, this.end);

  @override
  bool matches(int? codeUnit) => codeUnit != null && codeUnit >= start && codeUnit <= end;

  @override
  Map<String, dynamic> toJson() => {'type': 'range', 'start': start, 'end': end};
}

// ============================================================================
// SERIALIZABLE PATTERN SPECIFICATIONS
// ============================================================================

// ============================================================================
// STATE AND RULE SPECIFICATIONS
// ============================================================================

class StateSpec {
  final int id;
  final List<StateActionSpec> actions;

  const StateSpec(this.id, this.actions);

  Map<String, dynamic> toJson() => {'id': id, 'actions': actions.map((a) => a.toJson()).toList()};

  static StateSpec fromJson(Map<String, dynamic> json) {
    return StateSpec(
      json['id'] as int,
      (json['actions'] as List).cast<Map<String, dynamic>>().map(StateActionSpec.fromJson).toList(),
    );
  }
}

class RuleMetadataSpec {
  final String name;
  final List<int> firstStateIds;
  final bool isEmpty;

  const RuleMetadataSpec({required this.name, required this.firstStateIds, required this.isEmpty});

  Map<String, dynamic> toJson() => {
    'name': name,
    'firstStateIds': firstStateIds,
    'isEmpty': isEmpty,
  };

  static RuleMetadataSpec fromJson(Map<String, dynamic> json) {
    return RuleMetadataSpec(
      name: json['name'] as String,
      firstStateIds: (json['firstStateIds'] as List).cast<int>(),
      isEmpty: json['isEmpty'] as bool,
    );
  }
}

// ============================================================================
// EXPORTED STATE MACHINE
// ============================================================================

class ExportedStateMachine {
  final List<StateSpec> states;
  final List<int> initialStateIds;
  final PatternSymbol startSymbol;
  final Map<PatternSymbol, List<PatternSymbol>> childrenRegistry;
  final Map<String, RuleMetadataSpec> rules;
  final int version = 2;

  const ExportedStateMachine({
    required this.states,
    required this.initialStateIds,
    required this.startSymbol,
    required this.childrenRegistry,
    required this.rules,
  });

  String toJson() => jsonEncode({
    'version': version,
    'initialStates': initialStateIds,
    'startSymbol': startSymbol,
    'childrenRegistry': Map.fromEntries(
      childrenRegistry.entries.map((e) => MapEntry(e.key as String, e.value)),
    ),
    'states': states.map((s) => s.toJson()).toList(),
    'rules': rules.map((name, meta) => MapEntry(name, meta.toJson())),
  });

  static ExportedStateMachine fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    final states = (json['states'] as List)
        .cast<Map<String, dynamic>>()
        .map(StateSpec.fromJson)
        .toList();

    final childrenRegistry = (json['childrenRegistry'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(
        PatternSymbol(key),
        (value as List).cast<String>().map(PatternSymbol.new).toList(),
      ),
    );

    final rules = (json['rules'] as Map<String, dynamic>).map(
      (name, ruleJson) =>
          MapEntry(name, RuleMetadataSpec.fromJson(ruleJson as Map<String, dynamic>)),
    );

    return ExportedStateMachine(
      states: states,
      initialStateIds: (json['initialStates'] as List).cast<int>(),
      startSymbol: PatternSymbol(json['startSymbol'] as String),
      childrenRegistry: childrenRegistry,
      rules: rules,
    );
  }
}

// ============================================================================
// STATE MACHINE EXPORTER
// ============================================================================

class StateMachineExporter {
  static ExportedStateMachine export(StateMachine sm) {
    final stateSpecs = <StateSpec>[];

    // Convert each state to a spec
    for (final state in sm.states) {
      final actionSpecs = state.actions.map((action) {
        return _convertActionToSpec(action);
      }).toList();
      stateSpecs.add(StateSpec(state.id, actionSpecs));
    }

    // Convert rule metadata
    final ruleMap = <String, RuleMetadataSpec>{};
    for (final rule in sm.rules) {
      final firstStateIds = sm.ruleFirst[rule]?.map((s) => s.id).toList() ?? [];
      ruleMap[rule.name as String] = RuleMetadataSpec(
        name: rule.name as String,
        firstStateIds: firstStateIds,
        isEmpty: rule.empty(),
      );
    }

    return ExportedStateMachine(
      states: stateSpecs,
      initialStateIds: sm.initialStates.map((s) => s.id).toList(),
      startSymbol: sm.grammar.startSymbol,
      childrenRegistry: sm.grammar.childrenRegistry,
      rules: ruleMap,
    );
  }

  static StateActionSpec _convertActionToSpec(StateAction action) {
    return switch (action) {
      TokenAction(:var pattern, :var nextState) => TokenActionSpec(
        _tokenPatternToSpec(pattern),
        nextState.id,
      ),
      MarkAction(:var name, :var nextState) => MarkActionSpec(name, nextState.id),
      CallAction(:var rule, :var returnState, :var minPrecedenceLevel) => CallActionSpec(
        rule.name as String,
        returnState.id,
        minPrecedenceLevel,
      ),
      ReturnAction(:var rule, :var precedenceLevel) => ReturnActionSpec(
        rule.name as String,
        precedenceLevel,
      ),
      AcceptAction() => const AcceptActionSpec(),
      PredicateAction(:var isAnd, :var nextState, :var symbol, :var pattern) => PredicateActionSpec(
        isAnd: isAnd,
        symbol: symbol ?? pattern.symbolId!,
        nextStateId: nextState.id,
      ),
      SemanticAction(:var nextState, :var pattern) => SemanticActionCallSpec(
        (pattern?.symbolId as String?) ?? 'stub',
        nextState.id,
      ),
    };
  }

  static TokenSpec _tokenPatternToSpec(Pattern pattern) {
    if (pattern is Token) {
      final choice = pattern.choice;
      return switch (choice) {
        AnyToken() => const AnyTokenSpec(),
        ExactToken(:var value) => ExactTokenSpec(value),
        RangeToken(:var start, :var end) => RangeTokenSpec(start, end),
        _ => throw UnsupportedError('Cannot convert token choice to spec: ${choice.runtimeType}'),
      };
    }
    throw UnsupportedError('Cannot convert pattern to TokenSpec: ${pattern.runtimeType}');
  }
}
