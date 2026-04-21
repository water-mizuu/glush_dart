// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";

void main() {
  var grammar = r"S = $a a b | $a a b; a = 'a'; b = 'b'";
  var parser = grammar.toSMParser(startRuleName: "S");
  var result = parser.parseAmbiguous("ab").ambiguousSuccess()!;
  print(result.forest.inner.toDot());
}
