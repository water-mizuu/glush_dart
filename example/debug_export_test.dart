/// Debug test to understand export/import issue
import "dart:convert" show json;

import "package:glush/glush.dart";

void main() {
  print("=== Debug Export/Import Test ===\n");

  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser = SMParser(grammar);

  print("Original parser - recognize results:");
  print("  'a': ${parser.recognize("a")}");
  print("  'b': ${parser.recognize("b")}");
  print("  'c': ${parser.recognize("c")}\n");

  print("Original state machine structure:");
  var machine = parser.stateMachine;
  print("  Initial states: ${machine.initialStates.length}");
  print("  States: ${machine.states.length}");
  print("  Rules: ${machine.rules}");
  print("  Rule first mappings: ${machine.ruleFirst.length}\n");

  // Export
  var jsonString = machine.exportToJson();
  print("Exported JSON:");
  var data = json.decode(jsonString);
  print("  Version: ${data['version']}");
  print("  States: ${(data['states'] as List).length}");
  print("  Initial state IDs: ${data['initialStates']}");
  print("  Rules: ${data['rules']}");
  print("  Rule first: ${data['ruleFirst']}\n");

  // Export states detail
  print("State details:");
  for (var stateData in data["states"] as List) {
    print("  State ${stateData['id']}: ${(stateData['actions'] as List).length} actions");
    for (var action in stateData["actions"] as List) {
      print("    - ${action['type']}");
    }
  }
  print("");

  // Import
  var importedMachine = importFromJson(jsonString, grammar);

  print("Imported state machine structure:");
  print("  Initial states: ${importedMachine.initialStates.length}");
  print("  States: ${importedMachine.states.length}");
  print("  Rules: ${importedMachine.rules}");
  print("  Rule first mappings: ${importedMachine.ruleFirst.length}\n");

  print("Imported state machine states:");
  for (var state in importedMachine.states) {
    print("  State ${state.id}: ${state.actions.length} actions");
    for (var action in state.actions) {
      print("    - ${action.runtimeType}");
    }
  }
  print("");

  // Create parser from imported machine
  var importedParser = SMParser.fromStateMachine(importedMachine);

  print("Imported parser - recognize results:");
  print("  'a': ${importedParser.recognize("a")}");
  print("  'b': ${importedParser.recognize("b")}");
  print("  'c': ${importedParser.recognize("c")}\n");
}
