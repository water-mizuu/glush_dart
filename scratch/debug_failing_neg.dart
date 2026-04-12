import "package:glush/glush.dart";

void main() {
  print("--- Negation Debug Failing Test: Neg(ab) on 'abc' ---");
  var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Token.char("b"))));
  var parser = SMParser(grammar);

  // We want to see why Neg(ab) at 0 doesn't match 'abc' (j=3).
  var result = parser.parseAmbiguous("abc");
  print("Result: $result");

  if (result is ParseAmbiguousSuccess) {
    print("SUCCESS!");
    print("Derivations: ${result.forest.countDerivations()}");
  } else {
    print("FAILURE");
  }
}
