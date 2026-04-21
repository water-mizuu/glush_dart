// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";

void main() {
  var grammar = "S=group:((elem:'a')+)";
  var parser = grammar.toSMParser();
  var parseResult = parser.parse("aaa").success()!.rawMarks.evaluateStructure("aaa");
  print("Parse Tree (JSON):");
  print(parseResult.toJsonStringPretty());
}
