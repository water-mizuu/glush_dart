import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("counts match for more complex ambiguity S->SSS|SS|s", () {
    var grammar = Grammar(() {
      late Rule s;
      s = Rule("S", () {
        return Label("1", Token.char("s")) | // s
            Label("2", s() >> s()) |
            Label("3", s() >> s() >> s()) |
            Label("4", s() >> s() >> s() >> s());
      });
      return s;
    });

    var parser = SMParser(grammar);
    const testInput = "ssss";
    var derivationCount = parser.countAllParses(testInput);
    var result = parser.parseAmbiguous(testInput);
    expect(result, isA<ParseAmbiguousSuccess>());
    var derivations = result.ambiguousSuccess()!.forest.allMarkPaths().toList();

    expect(BigInt.from(derivations.length), equals(derivationCount));
    // ssss should have 11 parse trees
    expect(derivations.length, equals(11));
  });
}
