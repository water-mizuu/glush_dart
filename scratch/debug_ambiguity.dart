import "package:glush/glush.dart";
import "package:glush/src/parser/common/parse_result.dart";

void main() {
  var grammar = Grammar(() => Rule("S", () => Neg(Token.char("0")).plus()));
  var parser = SMParser(grammar);

  var res = parser.parseAmbiguous("123", captureTokensAsMarks: true);
  if (res is ParseAmbiguousSuccess) {
    var paths = res.forest.allMarkPaths().toList();
    print("Found ${paths.length} paths:");
    for (var i = 0; i < paths.length; i++) {
        print("Path $i:");
        var struct = paths[i].evaluateStructure();
        print("  Span: ${struct.span}");
        // print("  Tree: ${paths[i].toFullTreeString()}");
    }
  } else {
    print("Parse failed: $res");
  }
}
