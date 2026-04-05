/// Debug state equality
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

  print("State ID and equality comparison:\n");

  var states1 = machine1.states;
  var states2 = machine2.states;

  for (int i = 0; i < states1.length; i++) {
    var s1 = states1[i];
    var s2 = states2[i];

    print("Index $i:");
    print("  Original: State ${s1.id}");
    print("  Imported: State ${s2.id}");
    print("  s1 == s2: ${s1 == s2}");
    print("  s1.hashCode: ${s1.hashCode}, s2.hashCode: ${s2.hashCode}");
    print("  identical(s1, s2): ${identical(s1, s2)}");
    print("");
  }

  // Test set membership
  print("Set membership test:");
  var testSet = <State>{states1[0]};
  print("  Created set with states1[0]");
  print("  testSet.contains(states1[0]): ${testSet.contains(states1[0])}");
  print("  testSet.contains(states2[0]): ${testSet.contains(states2[0])}");
}
