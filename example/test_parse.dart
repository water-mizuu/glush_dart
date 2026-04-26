/// Test with full parse results
import "package:glush/glush.dart";

void main() {
  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser1 = SMParser(grammar);

  print("Original parser parse results:");
  for (var input in ["a", "b", "c"]) {
    var result = parser1.parse(input);
    print("  parse('$input'): $result");
  }
  print("");

  // Export and import
  var json = parser1.stateMachine.exportToJson();
  var machine2 = importFromJson(json);
  var parser2 = SMParser.fromStateMachine(machine2);

  print("Imported parser parse results:");
  for (var input in ["a", "b", "c"]) {
    var result = parser2.parse(input);
    print("  parse('$input'): $result");
  }
}
