import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

void main() {
  var grammar = r"""
    S = A "z" | B "y"
    A = "x"
    B = "x"
    """;
  var tracer = FileTracer("./trace.log");
  // var tracer = PrintTracer();
  var parser = grammar.toBCParser();
  File("graph.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  var input = "xz";
  var result = parser.parseAmbiguous(input, tracer: tracer);

  print(result);
}
