import "dart:io";

import "package:glush/glush.dart";

void main() {
  var grammar = r"""
    A = "x" B
    B = "y" A | "z"
    """;
  var parser = grammar.toSMParser();
  File("graph.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  var input = "xyxz";
  var result = parser.parseAmbiguous(input);

  print(result.ambiguousSuccess()!.forest);
}
