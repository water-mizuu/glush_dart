// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:glush/src/parser/common/tracer.dart";

void main() {
  var tracer = FileTracer("meta.log");
  var grammar = metaGrammarString;
  var parser = grammar.toSMParser();
  var result = parser.parseAmbiguous(metaGrammarString, tracer: tracer).ambiguousSuccess()!;
  print(result.forest.inner.toDot());
}
