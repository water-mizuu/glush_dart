// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";

void main() {
  var grammar = "S=group:(elem:'a')+ (if (pos == 3) '')";
  var parser = grammar.toSMParser();
  var input = "aaaa";
  var parseResult = parser.parse(input).success()!.rawMarks.evaluateStructure(input);
  print("Parse Tree (JSON):");
  print(parseResult.toJsonStringPretty());
}
