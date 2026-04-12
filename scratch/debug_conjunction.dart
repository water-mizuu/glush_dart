import "package:glush/glush.dart";
import "package:glush/src/parser/common/parse_result.dart";

void main() {
  var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") & Token.charRange("a", "z"))));
  var parser = SMParser(grammar);

  var res = parser.parseAmbiguous("b", captureTokensAsMarks: true);
  if (res is ParseAmbiguousSuccess) {
    var paths = res.forest.allMarkPaths().toList();
    print("Found ${paths.length} paths:");
  } else {
    print("Parse failed: $res");
  }
}
