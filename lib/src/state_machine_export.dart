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

  const CallActionSpec(this.ruleName, this.nextStateId);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'call',
    'ruleName': ruleName,
    'nextStateId': nextStateId,
  };

  static CallActionSpec fromJson(Map<String, dynamic> json) {
    return CallActionSpec(json['ruleName'] as String, json['nextStateId'] as int);
  }
}

class ReturnActionSpec extends StateActionSpec {
  final String ruleName;

  const ReturnActionSpec(this.ruleName);

  @override
  Map<String, dynamic> toJson() => {'type': 'return', 'ruleName': ruleName};

  static ReturnActionSpec fromJson(Map<String, dynamic> json) {
    return ReturnActionSpec(json['ruleName'] as String);
  }
}

class AcceptActionSpec extends StateActionSpec {
  const AcceptActionSpec();

  @override
  Map<String, dynamic> toJson() => {'type': 'accept'};
}

class PredicateActionSpec extends StateActionSpec {
  final bool isAnd;
  final int nextStateId;

  const PredicateActionSpec({required this.isAnd, required this.nextStateId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'predicate',
    'isAnd': isAnd,
    'nextStateId': nextStateId,
  };

  static PredicateActionSpec fromJson(Map<String, dynamic> json) {
    return PredicateActionSpec(
      isAnd: json['isAnd'] as bool,
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

/// Base class for serialized patterns
sealed class PatternSpec {
  const PatternSpec();

  Map<String, dynamic> toJson();

  /// Extract symbol ID if present, otherwise null
  PatternSymbol? getSymbolId() {
    return switch (this) {
      TokenPatternSpec(:var symbolId) => symbolId,
      EpsPatternSpec() => const PatternSymbol("eps"),
      MarkerPatternSpec(:var symbolId) => symbolId,
      AltPatternSpec(:var symbolId) => symbolId,
      SeqPatternSpec(:var symbolId) => symbolId,
      ConjPatternSpec(:var symbolId) => symbolId,
      PlusPatternSpec(:var symbolId) => symbolId,
      StarPatternSpec(:var symbolId) => symbolId,
      AndPatternSpec(:var symbolId) => symbolId,
      NotPatternSpec(:var symbolId) => symbolId,
      RuleCallPatternSpec(:var symbolId) => symbolId,
      CallPatternSpec(:var symbolId) => symbolId,
      PrecedenceLabeledPatternSpec(:var symbolId) => symbolId,
      ActionPatternSpec(:var symbolId) => symbolId,
    };
  }

  static PatternSpec fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      'token' => TokenPatternSpec.fromJson(json),
      'eps' => const EpsPatternSpec(),
      'marker' => MarkerPatternSpec.fromJson(json),
      'alt' => AltPatternSpec.fromJson(json),
      'seq' => SeqPatternSpec.fromJson(json),
      'conj' => ConjPatternSpec.fromJson(json),
      'plus' => PlusPatternSpec.fromJson(json),
      'star' => StarPatternSpec.fromJson(json),
      'and' => AndPatternSpec.fromJson(json),
      'not' => NotPatternSpec.fromJson(json),
      'rulecall' => RuleCallPatternSpec.fromJson(json),
      'call' => CallPatternSpec.fromJson(json),
      'precedence' => PrecedenceLabeledPatternSpec.fromJson(json),
      'action' => ActionPatternSpec.fromJson(json),
      _ => throw UnsupportedError('Unknown pattern type: $type'),
    };
  }
}

class TokenPatternSpec extends PatternSpec {
  final TokenSpec tokenSpec;
  final PatternSymbol? symbolId;

  const TokenPatternSpec({required this.tokenSpec, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'token',
    'tokenSpec': tokenSpec.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static TokenPatternSpec fromJson(Map<String, dynamic> json) {
    return TokenPatternSpec(
      tokenSpec: TokenSpec.fromJson(json['tokenSpec'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException("Invalid Format"),
      },
    );
  }
}

class EpsPatternSpec extends PatternSpec {
  const EpsPatternSpec();

  @override
  Map<String, dynamic> toJson() => {'type': 'eps'};
}

class MarkerPatternSpec extends PatternSpec {
  final String name;
  final PatternSymbol? symbolId;

  const MarkerPatternSpec({required this.name, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'marker',
    'name': name,
    if (symbolId != null) 'symbolId': symbolId,
  };

  static MarkerPatternSpec fromJson(Map<String, dynamic> json) {
    return MarkerPatternSpec(
      name: json['name'] as String,
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class AltPatternSpec extends PatternSpec {
  final PatternSpec left;
  final PatternSpec right;
  final PatternSymbol? symbolId;

  const AltPatternSpec({required this.left, required this.right, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'alt',
    'left': left.toJson(),
    'right': right.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static AltPatternSpec fromJson(Map<String, dynamic> json) {
    return AltPatternSpec(
      left: PatternSpec.fromJson(json['left'] as Map<String, dynamic>),
      right: PatternSpec.fromJson(json['right'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class SeqPatternSpec extends PatternSpec {
  final PatternSpec left;
  final PatternSpec right;
  final PatternSymbol? symbolId;

  const SeqPatternSpec({required this.left, required this.right, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'seq',
    'left': left.toJson(),
    'right': right.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static SeqPatternSpec fromJson(Map<String, dynamic> json) {
    return SeqPatternSpec(
      left: PatternSpec.fromJson(json['left'] as Map<String, dynamic>),
      right: PatternSpec.fromJson(json['right'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class ConjPatternSpec extends PatternSpec {
  final PatternSpec left;
  final PatternSpec right;
  final PatternSymbol? symbolId;

  const ConjPatternSpec({required this.left, required this.right, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'conj',
    'left': left.toJson(),
    'right': right.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static ConjPatternSpec fromJson(Map<String, dynamic> json) {
    return ConjPatternSpec(
      left: PatternSpec.fromJson(json['left'] as Map<String, dynamic>),
      right: PatternSpec.fromJson(json['right'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class PlusPatternSpec extends PatternSpec {
  final PatternSpec child;
  final PatternSymbol? symbolId;

  const PlusPatternSpec({required this.child, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'plus',
    'child': child.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static PlusPatternSpec fromJson(Map<String, dynamic> json) {
    return PlusPatternSpec(
      child: PatternSpec.fromJson(json['child'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class StarPatternSpec extends PatternSpec {
  final PatternSpec child;
  final PatternSymbol? symbolId;

  const StarPatternSpec({required this.child, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'star',
    'child': child.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static StarPatternSpec fromJson(Map<String, dynamic> json) {
    return StarPatternSpec(
      child: PatternSpec.fromJson(json['child'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class AndPatternSpec extends PatternSpec {
  final PatternSpec pattern;
  final PatternSymbol? symbolId;

  const AndPatternSpec({required this.pattern, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'and',
    'pattern': pattern.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static AndPatternSpec fromJson(Map<String, dynamic> json) {
    return AndPatternSpec(
      pattern: PatternSpec.fromJson(json['pattern'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class NotPatternSpec extends PatternSpec {
  final PatternSpec pattern;
  final PatternSymbol? symbolId;

  const NotPatternSpec({required this.pattern, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'not',
    'pattern': pattern.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static NotPatternSpec fromJson(Map<String, dynamic> json) {
    return NotPatternSpec(
      pattern: PatternSpec.fromJson(json['pattern'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class RuleCallPatternSpec extends PatternSpec {
  final String ruleName;
  final PatternSymbol? symbolId;

  const RuleCallPatternSpec({required this.ruleName, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'rulecall',
    'ruleName': ruleName,
    if (symbolId != null) 'symbolId': symbolId,
  };

  static RuleCallPatternSpec fromJson(Map<String, dynamic> json) {
    return RuleCallPatternSpec(
      ruleName: json['ruleName'] as String,
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class CallPatternSpec extends PatternSpec {
  final String ruleName;
  final int minPrecedenceLevel;
  final PatternSymbol? symbolId;

  const CallPatternSpec({required this.ruleName, required this.minPrecedenceLevel, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'call',
    'ruleName': ruleName,
    'minPrecedenceLevel': minPrecedenceLevel,
    if (symbolId != null) 'symbolId': symbolId,
  };

  static CallPatternSpec fromJson(Map<String, dynamic> json) {
    return CallPatternSpec(
      ruleName: json['ruleName'] as String,
      minPrecedenceLevel: json['minPrecedenceLevel'] as int,
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class PrecedenceLabeledPatternSpec extends PatternSpec {
  final int precedenceLevel;
  final PatternSpec pattern;
  final PatternSymbol? symbolId;

  const PrecedenceLabeledPatternSpec({
    required this.precedenceLevel,
    required this.pattern,
    this.symbolId,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'precedence',
    'precedenceLevel': precedenceLevel,
    'pattern': pattern.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static PrecedenceLabeledPatternSpec fromJson(Map<String, dynamic> json) {
    return PrecedenceLabeledPatternSpec(
      precedenceLevel: json['precedenceLevel'] as int,
      pattern: PatternSpec.fromJson(json['pattern'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

class ActionPatternSpec extends PatternSpec {
  final PatternSpec child;
  final PatternSymbol? symbolId;

  const ActionPatternSpec({required this.child, this.symbolId});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'action',
    'child': child.toJson(),
    if (symbolId != null) 'symbolId': symbolId,
  };

  static ActionPatternSpec fromJson(Map<String, dynamic> json) {
    return ActionPatternSpec(
      child: PatternSpec.fromJson(json['child'] as Map<String, dynamic>),
      symbolId: switch (json['symbolId']) {
        String id => PatternSymbol(id),
        null => null,
        _ => throw FormatException(),
      },
    );
  }
}

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
  final PatternSpec? patternSpec;

  const RuleMetadataSpec({
    required this.name,
    required this.firstStateIds,
    required this.isEmpty,
    this.patternSpec,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'firstStateIds': firstStateIds,
    'isEmpty': isEmpty,
    if (patternSpec != null) 'patternSpec': patternSpec!.toJson(),
  };

  static RuleMetadataSpec fromJson(Map<String, dynamic> json) {
    return RuleMetadataSpec(
      name: json['name'] as String,
      firstStateIds: (json['firstStateIds'] as List).cast<int>(),
      isEmpty: json['isEmpty'] as bool,
      patternSpec: json['patternSpec'] != null
          ? PatternSpec.fromJson(json['patternSpec'] as Map<String, dynamic>)
          : null,
    );
  }
}

// ============================================================================
// EXPORTED STATE MACHINE
// ============================================================================

class ExportedStateMachine {
  final List<StateSpec> states;
  final List<int> initialStateIds;
  final Map<String, RuleMetadataSpec> rules;
  final int version = 1;

  const ExportedStateMachine({
    required this.states,
    required this.initialStateIds,
    required this.rules,
  });

  String toJson() => jsonEncode({
    'version': version,
    'initialStates': initialStateIds,
    'states': states.map((s) => s.toJson()).toList(),
    'rules': rules.map((name, meta) => MapEntry(name, meta.toJson())),
  });

  static ExportedStateMachine fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    final states = (json['states'] as List)
        .cast<Map<String, dynamic>>()
        .map(StateSpec.fromJson)
        .toList();

    final rules = (json['rules'] as Map<String, dynamic>).map(
      (name, ruleJson) =>
          MapEntry(name, RuleMetadataSpec.fromJson(ruleJson as Map<String, dynamic>)),
    );

    return ExportedStateMachine(
      states: states,
      initialStateIds: (json['initialStates'] as List).cast<int>(),
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

    // Convert rule metadata and patterns
    final ruleMap = <String, RuleMetadataSpec>{};
    for (final rule in sm.rules) {
      final firstStateIds = sm.ruleFirst[rule]?.map((s) => s.id).toList() ?? [];
      final patternSpec = _patternToSpec(rule.body());
      ruleMap[rule.name as String] = RuleMetadataSpec(
        name: rule.name as String,
        firstStateIds: firstStateIds,
        isEmpty: rule.empty(),
        patternSpec: patternSpec,
      );
    }

    return ExportedStateMachine(
      states: stateSpecs,
      initialStateIds: sm.initialStates.map((s) => s.id).toList(),
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
      CallAction(:var rule, :var returnState) => CallActionSpec(
        rule.name as String,
        returnState.id,
      ),
      ReturnAction(:var rule) => ReturnActionSpec(rule.name as String),
      AcceptAction() => const AcceptActionSpec(),
      PredicateAction(:var isAnd, :var nextState) => PredicateActionSpec(
        isAnd: isAnd,
        nextStateId: nextState.id,
      ),
      SemanticAction(:var nextState) => SemanticActionCallSpec('stub', nextState.id),
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

  static PatternSpec _patternToSpec(Pattern pattern) {
    return switch (pattern) {
      Token() => TokenPatternSpec(
        tokenSpec: _tokenPatternToSpec(pattern),
        symbolId: pattern.symbolId,
      ),
      Eps() => EpsPatternSpec(),
      Marker(:var name) => MarkerPatternSpec(name: name, symbolId: pattern.symbolId),
      Alt(:var left, :var right) => AltPatternSpec(
        left: _patternToSpec(left),
        right: _patternToSpec(right),
        symbolId: pattern.symbolId,
      ),
      Seq(:var left, :var right) => SeqPatternSpec(
        left: _patternToSpec(left),
        right: _patternToSpec(right),
        symbolId: pattern.symbolId,
      ),
      Conj(:var left, :var right) => ConjPatternSpec(
        left: _patternToSpec(left),
        right: _patternToSpec(right),
        symbolId: pattern.symbolId,
      ),
      Plus(:var child) => PlusPatternSpec(child: _patternToSpec(child), symbolId: pattern.symbolId),
      Star(:var child) => StarPatternSpec(child: _patternToSpec(child), symbolId: pattern.symbolId),
      And(:var pattern) => AndPatternSpec(
        pattern: _patternToSpec(pattern),
        symbolId: pattern.symbolId,
      ),
      Not(:var pattern) => NotPatternSpec(
        pattern: _patternToSpec(pattern),
        symbolId: pattern.symbolId,
      ),
      RuleCall(:var rule) => RuleCallPatternSpec(
        ruleName: rule.name as String,
        symbolId: pattern.symbolId,
      ),
      Call(:var rule, :var minPrecedenceLevel) => CallPatternSpec(
        ruleName: rule.name as String,
        minPrecedenceLevel: minPrecedenceLevel ?? 0,
        symbolId: pattern.symbolId,
      ),
      PrecedenceLabeledPattern(:var precedenceLevel, child: var pattern) =>
        PrecedenceLabeledPatternSpec(
          precedenceLevel: precedenceLevel,
          pattern: _patternToSpec(pattern),
          symbolId: pattern.symbolId,
        ),
      Action(:var child) => ActionPatternSpec(
        child: _patternToSpec(child),
        symbolId: pattern.symbolId,
      ),
      _ => throw UnsupportedError('Cannot serialize pattern: ${pattern.runtimeType}'),
    };
  }
}
