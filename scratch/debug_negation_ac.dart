import "package:glush/glush.dart";

void main() {
  print("--- Negation Debug Start (ac) ---");
  var grammar = Grammar(() => Rule("S", () => Neg(Seq(Token.char("a"), Token.char("b")))));
  var parser = SMParser(grammar);

  print("Input: 'ac'");
  var res = parser.parseAmbiguous("ac");
  print("Result: $res");

  if (res is ParseAmbiguousSuccess) {
    print("SUCCESS (CORRECT if it matched 'ac')");
    var forest = res.forest;
    for (var path in forest.allMarkPaths()) {
      var struct = path.evaluateStructure();
      print("Path span: '${struct.span}'");
    }
  } else {
    print("FAILURE (UNCERTAIN)");
    if (res is ParseError) {
      print("Error at position: ${res.position}");
    }
  }
}
