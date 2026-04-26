// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";

void main() {
  var grammar = metaGrammarString.toGrammar();
  print(grammar.labelMapping.join("\n"));
  // var parser = grammar.toSMParser();
  // var input = "ssss";
  // var parseResult = parser
  //     .parseAmbiguous(input)
  //     .ambiguousSuccess()!
  //     .forest
  //     .map((v) => v.evaluateStructure(input).toSimple())
  //     .toList();
  // print(parseResult.join("\n"));
}
