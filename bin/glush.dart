// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";

void main() {
  var grammar = r"S= $2 &(S S) S S | $1 's'";
  var parser = grammar.toSMParser();
  var input = "ssss";
  var parseResult = parser
      .parseAmbiguous(input)
      .ambiguousSuccess()!
      .forest
      .map((v) => v.evaluateStructure(input).toJson())
      .toList();
  print(parseResult.join("\n"));
}
