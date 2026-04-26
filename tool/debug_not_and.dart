import "package:glush/glush.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";

void main() {
  var grammar =
      """
      S = !(&a b) (a | b)
      a = "a"
      b = "b"
      """
          .toGrammar();

  var smParser = SMParser(grammar);
  var bcParser = BCParser(grammar);

  for (var input in ["a", "b", "ab", "c", ""]) {
    var sm = smParser.recognize(input);
    var bc = bcParser.recognize(input);
    print("'$input': SM=$sm  BC=$bc  ${sm == bc ? 'OK' : 'MISMATCH!'}");
  }
}
