/// Deep comparison of machines
import "dart:convert" show json;

import "package:glush/glush.dart";

void main() {
  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser1 = SMParser(grammar);
  var machine1 = parser1.stateMachine;

  // Check starting states
  print("Original machine:");
  print("  initialStates length: ${machine1.initialStates.length}");
  if (machine1.initialStates.isNotEmpty) {
    var initState = machine1.initialStates[0];
    print("  initState ID: ${initState.id}");
    print("  initState actions: ${initState.actions}");
  }
  print("");

  //Export and import
  var jsonString = machine1.exportToJson();
  var jsonData = json.decode(jsonString) as Map<String, Object?>;
  print("JSON export:");
  print("  initialStates: ${jsonData['initialStates']}");
  print("  ruleFirst: ${jsonData['ruleFirst']}");
  print("");

  var machine2 = importFromJson(jsonString, grammar);

  print("Imported machine:");
  print("  initialStates length: ${machine2.initialStates.length}");
  if (machine2.initialStates.isNotEmpty) {
    var initState = machine2.initialStates[0];
    print("  initState ID: ${initState.id}");
    print("  initState actions: ${initState.actions}");
    print("  initState == machine1.initialStates[0]: ${initState == machine1.initialStates[0]}");
  }
  print("");

  // Check states
  print("All states comparison:");
  for (int i = 0; i < machine1.states.length; i++) {
    var s1 = machine1.states[i];
    var s2 = machine2.states.firstWhere((s) => s.id == s1.id);
    print("  State ${s1.id}: ${s1.actions.length} actions vs ${s2.actions.length} actions");
  }
}
