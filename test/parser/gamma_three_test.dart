import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("counts match for more complex ambiguity S->SSS|SS|s", () {
    var grammar = Grammar(() {
      late Rule s;
      s = Rule("S", () {
        return Token.char("s") | // s
            (Marker("") >> s() >> s()) |
            (Marker("") >> s() >> s() >> s()) |
            (Marker("") >> s() >> s() >> s() >> s());
      });
      return s;
    });

    var parser = SMParser(grammar);
    const testInput = "ssss";
    var derivationCount = parser.countAllParses(testInput);
    var derivations = parser.enumerateAllParses(testInput).toList();
    var forestResult = parser.parseWithForest(testInput);
    expect(forestResult, isA<ParseForestSuccess>());

    if (forestResult is ParseForestSuccess) {
      Set<String> enumerations =
          derivations //
              .map((s) => s.toPrecedenceString(testInput))
              .toSet();
      Set<String> forestExtracted = forestResult.forest
          .extract()
          .map((s) => s.toPrecedenceString(testInput))
          .toSet();

      var trees = forestResult.forest.extract().toList();
      expect(enumerations.difference(forestExtracted), equals(<String>{}));
      expect(forestExtracted.difference(enumerations), equals(<String>{}));
      // Both enumeration and forest extraction should find the same number
      expect(derivations.length, equals(trees.length));
      expect(derivations.length, equals(derivationCount));
      // sss has 3 parse trees:
      // 1. SSS -> s+s+s
      // 2. SS -> (s+s)+s
      // 3. SS -> s+(s+s)
      expect(derivations.length, equals(11));
    }
  });
}
