/// Test with tracing
import "package:glush/glush.dart";

void main() {
  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser1 = SMParser(grammar);

  print("Original parser:");
  for (var input in ["a", "b", "c"]) {
    var result = parser1.recognize(input);
    print("  recognize('$input'): $result");
  }
  print("");

  // Export and import
  var json = parser1.stateMachine.exportToJson();
  var machine2 = importFromJson(json, grammar);
  var parser2 = SMParser.fromStateMachine(machine2);

  print("Imported parser:");
  for (var input in ["a", "b", "c"]) {
    var result = parser2.recognize(input);
    print("  recognize('$input'): $result");
  }
  print("");

  // Compare machines
  print("Machine comparison:");
  print("Original initialStates: ${parser1.stateMachine.initialStates}");
  print("Imported initialStates: ${parser2.stateMachine.initialStates}");
  print("");

  // Check ruleFirst mapping
  print("Original ruleFirst:");
  for (var i = 0; i < parser1.stateMachine.ruleFirst.length; i++) {
    var state = parser1.stateMachine.ruleFirst[i];
    if (state != null) {
      print("  $i -> ${state.id}");
    }
  }
  print("Imported ruleFirst:");
  for (var i = 0; i < parser2.stateMachine.ruleFirst.length; i++) {
    var state = parser2.stateMachine.ruleFirst[i];
    if (state != null) {
      print("  $i -> ${state.id}");
    }
  }
}
