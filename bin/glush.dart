import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

void main() {
  // var tracer = FileTracer("./trace.log");
  var grammar = r"S = S S | 's'".toGrammar();
  var parser = grammar.toSMParser();

  print(grammar.stateMachine.toDot());

  var tracer = FileTracer("./trace.log");
  var input = "sss";
  var parseResult = parser.parseAmbiguous(input, tracer: tracer).ambiguousSuccess()!.forest;
  stdout.writeln(parseResult.derivationCount);
}
