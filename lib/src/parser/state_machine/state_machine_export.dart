/// Serialization and deserialization of compiled state machines
///
/// This module provides functionality to export a fully compiled StateMachine
/// to JSON format and import it back without requiring grammar recompilation.
library glush.state_machine_export;

import "dart:convert" show json;

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// Serializes a StateAction to JSON.
Map<String, Object?> _serializeAction(StateAction action, Map<State, int> stateIdMap) {
  return switch (action) {
    TokenAction() => {
      "type": "token",
      "choice": action.choice.toJson(),
      "nextState": stateIdMap[action.nextState],
    },
    MarkAction() => {
      "type": "mark",
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    BoundaryAction() => {
      "type": "boundary",
      "kind": action.kind.name,
      "nextState": stateIdMap[action.nextState],
    },
    LabelStartAction() => {
      "type": "labelStart",
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    LabelEndAction() => {
      "type": "labelEnd",
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    BackreferenceAction() => {
      "type": "backreference",
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    ParameterAction() => {
      "type": "parameter",
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    ParameterCallAction() => {
      "type": "parameterCall",
      "pattern": action.pattern.toJson(),
      "nextState": stateIdMap[action.nextState],
    },
    ParameterStringAction() => {
      "type": "parameterString",
      "codeUnit": action.codeUnit,
      "nextState": stateIdMap[action.nextState],
    },
    ParameterPredicateAction() => {
      "type": "parameterPredicate",
      "isAnd": action.isAnd,
      "name": action.name,
      "nextState": stateIdMap[action.nextState],
    },
    CallAction() => {
      "type": "call",
      "ruleName": action.rule.name.symbol,
      "pattern": action.pattern,
      "minPrecedenceLevel": action.minPrecedenceLevel,
      "returnState": stateIdMap[action.returnState],
    },
    TailCallAction() => {
      "type": "tailCall",
      "ruleName": action.rule.name.symbol,
      "pattern": action.pattern.toJson(),
      "minPrecedenceLevel": action.minPrecedenceLevel,
    },
    ReturnAction() => {
      "type": "return",
      "ruleName": action.rule.name.symbol,
      "precedenceLevel": action.precedenceLevel,
    },
    AcceptAction() => {"type": "accept"},
    PredicateAction() => {
      "type": "predicate",
      "isAnd": action.isAnd,
      "symbol": action.symbol.symbol,
      "nextState": stateIdMap[action.nextState],
    },
    ConjunctionAction() => {
      "type": "conjunction",
      "leftSymbol": action.leftSymbol.symbol,
      "rightSymbol": action.rightSymbol.symbol,
      "nextState": stateIdMap[action.nextState],
    },
    NegationAction() => {
      "type": "negation",
      "symbol": action.symbol.symbol,
      "nextState": stateIdMap[action.nextState],
    },
  };
}

/// Deserializes a StateAction from JSON.
StateAction _deserializeAction(
  Map<String, Object?> json,
  Map<int, State> stateMap,
  Map<String, Rule> ruleMap,
) {
  var type = json["type"]! as String;
  return switch (type) {
    "token" => TokenAction(
      TokenChoice.fromJson(json["choice"]! as Map<String, Object?>),
      stateMap[json["nextState"]]!,
    ),
    "mark" => MarkAction(
      json["name"]! as String,
      Marker(json["name"]! as String),
      stateMap[json["nextState"]]!,
    ),
    "boundary" => BoundaryAction(
      json["kind"] == "start" ? BoundaryKind.start : BoundaryKind.eof,
      json["kind"] == "start" ? StartAnchor() : EofAnchor(),
      stateMap[json["nextState"]]!,
    ),
    "labelStart" => LabelStartAction(json["name"]! as String, stateMap[json["nextState"]]!),
    "labelEnd" => LabelEndAction(json["name"]! as String, stateMap[json["nextState"]]!),
    "backreference" => BackreferenceAction(json["name"]! as String, stateMap[json["nextState"]]!),
    "parameter" => ParameterAction(
      json["name"]! as String,
      ParameterRefPattern(json["name"]! as String),
      stateMap[json["nextState"]]!,
    ),
    "parameterCall" => ParameterCallAction(
      Pattern.fromJson(json["pattern"]! as Map<String, Object?>, ruleMap) as ParameterCallPattern,
      stateMap[json["nextState"]]!,
    ),
    "parameterString" => ParameterStringAction(
      json["codeUnit"]! as int,
      stateMap[json["nextState"]]!,
    ),
    "parameterPredicate" => ParameterPredicateAction(
      isAnd: json["isAnd"]! as bool,
      name: json["name"]! as String,
      nextState: stateMap[json["nextState"]]!,
    ),
    "call" => CallAction(
      ruleMap[json["ruleName"]]!,
      Pattern.fromJson(json["pattern"]! as Map<String, Object?>, ruleMap),
      stateMap[json["returnState"]]!,
      json["minPrecedenceLevel"] as int?,
    ),
    "tailCall" => TailCallAction(
      ruleMap[json["ruleName"]]!,
      Pattern.fromJson(json["pattern"]! as Map<String, Object?>, ruleMap),
      json["minPrecedenceLevel"] as int?,
    ),
    "return" => ReturnAction(ruleMap[json["ruleName"]]!, Eps(), json["precedenceLevel"] as int?),
    "accept" => const AcceptAction(),
    "predicate" => PredicateAction(
      isAnd: json["isAnd"]! as bool,
      symbol: PatternSymbol(json["symbol"]! as String),
      nextState: stateMap[json["nextState"]]!,
    ),
    "conjunction" => ConjunctionAction(
      leftSymbol: PatternSymbol(json["leftSymbol"]! as String),
      rightSymbol: PatternSymbol(json["rightSymbol"]! as String),
      nextState: stateMap[json["nextState"]]!,
    ),
    "negation" => NegationAction(
      symbol: PatternSymbol(json["symbol"]! as String),
      nextState: stateMap[json["nextState"]]!,
    ),
    _ => throw UnsupportedError("Unknown action type: $type"),
  };
}

/// Extension on StateMachine for export functionality
extension StateMachineExport on StateMachine {
  /// Export this compiled state machine to JSON format.
  String exportToJson() {
    var stateIdMap = <State, int>{};
    var stateList = states;
    for (int i = 0; i < stateList.length; i++) {
      stateIdMap[stateList[i]] = stateList[i].id;
    }

    var statesJson = stateList.map((state) {
      return {
        "id": state.id,
        "actions": state.actions.map((action) => _serializeAction(action, stateIdMap)).toList(),
      };
    }).toList();

    var initialStateIds = initialStates.map((s) => s.id).toList();
    var rulesJson = grammar.rules
        .map(
          (rule) => {
            "symbolId": rule.symbolId!.symbol,
            "name": rule.name.symbol,
            if (rule.guard != null) "guard": rule.guard!.toJson(),
          },
        )
        .toList();

    var ruleFirstJson = <String, int>{};
    ruleFirst.forEach((symbol, state) {
      ruleFirstJson[symbol.symbol] = state.id;
    });

    var export = {
      "version": "1.0",
      "states": statesJson,
      "initialStates": initialStateIds,
      "rules": rulesJson,
      "ruleFirst": ruleFirstJson,
      "startSymbol": grammar.startSymbol.symbol,
      "startCall": grammar.startCall.toJson(),
    };

    return json.encode(export);
  }
}

/// Import a previously exported state machine from JSON.
/// If grammar is not provided, a ShellGrammar is reconstructed.
StateMachine importFromJson(String jsonString, [GrammarInterface? grammar]) {
  var data = json.decode(jsonString) as Map<String, Object?>;

  if (data["version"] != "1.0") {
    throw ArgumentError("Unsupported export version: ${data["version"]}");
  }

  // Create all states first
  var stateMap = <int, State>{};
  var statesData = data["states"]! as List<Object?>;

  for (var stateData in statesData.cast<Map<String, Object?>>()) {
    var id = stateData["id"]! as int;
    stateMap[id] = State(id, []);
  }

  // Reconstruction or use provided grammar
  var ruleMap = <String, Rule>{};
  if (grammar != null) {
    for (var rule in grammar.rules) {
      ruleMap[rule.name.symbol] = rule;
    }
  } else {
    // Collect all rule names and create stubs
    var rulesData = data["rules"]! as List<Object?>;
    for (var serializedRule in rulesData.cast<Map<String, Object?>>()) {
      var name = serializedRule["name"]! as String;
      var rule = Rule(name, () => Eps());
      rule.symbolId = PatternSymbol(serializedRule["symbolId"]! as String);
      if (serializedRule.containsKey("guard")) {
        rule.guard = GuardExpr.fromJson(serializedRule["guard"]! as Map<String, Object?>, ruleMap);
      }
      ruleMap[name] = rule;
    }

    var startSymbol = PatternSymbol(data["startSymbol"]! as String);
    var startCallJson = data["startCall"]! as Map<String, Object?>;
    var startCall = Pattern.fromJson(startCallJson, ruleMap) as RuleCall;

    grammar = ShellGrammar(
      startSymbol: startSymbol,
      childrenRegistry: const {}, // SPPF will degrade for non-matched rules
      rules: ruleMap.values.toList(),
      startCall: startCall,
    );
  }

  // Add actions to states
  for (var stateData in statesData.cast<Map<String, Object?>>()) {
    var id = stateData["id"]! as int;
    var state = stateMap[id]!;
    var actions = stateData["actions"]! as List<Object?>;

    for (var actionData in actions) {
      var action = _deserializeAction(actionData! as Map<String, Object?>, stateMap, ruleMap);
      state.actions.add(action);
    }
  }

  // Reconstruct initial states
  var initialStateIds = (data["initialStates"]! as List<Object?>).cast<int>();
  var initialStates = initialStateIds.map((id) => stateMap[id]!).toList();

  // Reconstruct rule-first mappings
  var ruleFirstData = data["ruleFirst"]! as Map<String, Object?>;
  var ruleFirstMapping = <PatternSymbol, State>{};
  ruleFirstData.forEach((symbolId, stateId) {
    ruleFirstMapping[PatternSymbol(symbolId)] = stateMap[stateId! as int]!;
  });

  // Create and initialize machine
  var machine = StateMachine.empty(grammar);
  machine.ruleFirst.addAll(ruleFirstMapping);

  var rulesData = data["rules"]! as List<Object?>;
  for (var ruleData in rulesData.cast<Map<String, Object?>>()) {
    machine.rules.add(PatternSymbol(ruleData["symbolId"]! as String));
  }

  // Initialize from imported data
  machine.initializeFromJson(initialStates, stateMap.values.toList());

  return machine;
}
