/// Detailed state and action comparison
import "package:glush/glush.dart";

void main() {
  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser1 = SMParser(grammar);
  var machine1 = parser1.stateMachine;

  // Export and import
  var json = machine1.exportToJson();
  var machine2 = importFromJson(json, grammar);

  print("State structure comparison:\n");

  for (int i = 0; i < machine1.states.length; i++) {
    var s1 = machine1.states[i];
    var s2 = machine2.states[i];

    print("State $i:");
    print("  Original ID: ${s1.id}, Imported ID: ${s2.id}");
    print("  Original actions: ${s1.actions.length}, Imported actions: ${s2.actions.length}");

    for (int j = 0; j < s1.actions.length; j++) {
      var a1 = s1.actions[j];
      var a2 = s2.actions[j];

      print("  Action $j: ${a1.runtimeType}");

      if (a1 is TokenAction) {
        var ta1 = a1;
        var ta2 = a2 as TokenAction;
        print("    Original nextState: ${ta1.nextState.id}");
        print("    Imported nextState: ${ta2.nextState.id}");
        print("    Reference equality: ${identical(ta1.nextState, ta2.nextState)}");
        print("    ID equality: ${ta1.nextState.id == ta2.nextState.id}");
      } else if (a1 is CallAction) {
        var ca1 = a1;
        var ca2 = a2 as CallAction;
        print("    Original returnState: ${ca1.returnState.id}");
        print("    Imported returnState: ${ca2.returnState.id}");
        print("    Original rule: ${ca1.ruleSymbol}");
        print("    Imported rule: ${ca2.ruleSymbol}");
      } else if (a1 is AcceptAction) {
        print("    (no state reference)");
      }
    }
    print("");
  }
}
