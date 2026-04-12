import "package:glush/glush.dart";

void main() {
  print("--- Negation Debug: Neg('a') on 'a' ---");
  var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
  var parser = SMParser(grammar);

  // We want to see why Neg('a') matches 'a' (it shouldn't).
  var result = parser.parseAmbiguous("a");
  print("Result: $result");
}
