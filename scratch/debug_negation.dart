import "package:glush/glush.dart";

void main() {
  print("--- Negation Debug Start ---");
  var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
  var parser = SMParser(grammar);

  print("Input: empty string");
  var res = parser.parseAmbiguous("");
  print("Result: $res");

  if (res is ParseAmbiguousSuccess) {
    print("SUCCESS (WRONG!)");
    var forest = res.forest;
    print("Derivations: ${forest.countDerivations()}");
    for (var path in forest.allMarkPaths()) {
      print("Path span: '${path.evaluateStructure().span}'");
    }
  } else {
    print("FAILURE (CORRECT!)");
  }
}
