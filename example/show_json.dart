/// Export JSON for inspection
import "dart:convert" show json;

import "package:glush/glush.dart";

void main() {
  const grammarSource = r"""
S = 'a' | 'b'
""";

  var grammar = grammarSource.toGrammar();
  var parser = SMParser(grammar);
  var jsonString = parser.stateMachine.exportToJson();

  print(json.encode(json.decode(jsonString)));
}
