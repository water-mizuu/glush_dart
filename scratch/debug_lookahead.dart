import "package:glush/glush.dart";

void main() {
  var grammar = Grammar(() => Rule("S", () => Neg(Seq(And(Token.char("a")), Token.char("a")))));
  var parser = SMParser(grammar);

  var res = parser.parseAmbiguous("b", captureTokensAsMarks: true);
  if (res is ParseAmbiguousSuccess) {
    print("Found paths");
  } else {
    print("Parse failed: res");
  }
}
