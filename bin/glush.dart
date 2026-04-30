import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

void main() {
  var grammar = r"""
    A = "x" B
    B = "y" A | "z"
    """;
  // var tracer = FileTracer("./trace.log");
  var tracer = PrintTracer();
  var parser = grammar.toSMParser();
  File("graph.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  var input = "xyxz";
  var result = parser.parseAmbiguous(input, tracer: tracer);

  print(result);
}
