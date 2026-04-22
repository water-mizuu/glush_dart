// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";

void main() {
  var grammar = r"S= $2 &(a:S a) l:S r:S | $1 's'";
  var parser = grammar.toSMParser();
  var input = "ssss";
  var parseResult = parser
      .parseAmbiguous(input)
      .ambiguousSuccess()!
      .forest
      .map(
        (v) => Evaluator({
          r"S.2": (ctx) => "(${ctx("l")}${ctx("r")})",
          r"S.1": (ctx) => "s",
        }).evaluate(v.evaluateStructure(input)),
      )
      .toList();
  print(parseResult.join("\n"));
}
