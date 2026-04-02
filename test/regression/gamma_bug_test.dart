import "package:glush/glush.dart";
import "package:test/test.dart";

int counter = 0;

void main() {
  group("gamma 3 related bugs", () {
    evaluateGamma3(
      Grammar(() {
        late Rule s;
        s = Rule("S", () {
          return Label("1", Token.char("s")) | // s
              Label("2", s() >> s()) |
              Label("3", s() >> s() >> s()) |
              Label("4", s() >> s() >> s() >> s());
        });
        return s;
      }),
    );

    evaluateGamma3(
      Grammar(() {
        late Rule s;
        s = Rule("S", () {
          return Token.char("s") | // s
              (Marker("1") >> s() >> s()) |
              (Marker("2") >> s() >> s() >> s()) |
              (Marker("3") >> s() >> s() >> s() >> s());
        });
        return s;
      }),
    );

    evaluateGamma3(
      Grammar(() {
        late Rule s;
        s = Rule("S", () {
          return Marker("T") >>
              ((Token.char("s")) | // s
                  (s() >> s()) |
                  (s() >> s() >> s()) |
                  (s() >> s() >> s() >> s()));
        });
        return s;
      }),
    );
  });
}

void evaluateGamma3(Grammar grammar) {
  const testInput = "ssss";
  var parser = SMParser(grammar);
  var derivationCount = parser.countAllParses(testInput);
  var derivations =
      parser.parseAmbiguous(testInput).ambiguousSuccess()?.forest.allPaths().toList() ?? [];

  var result = parser.parseAmbiguous(testInput);
  test("Grammar ${counter++}", () {
    expect(result, isA<ParseAmbiguousSuccess>());

    // Verify counts match
    expect(derivations.length, equals(derivationCount));
    // ssss should have 11 parse trees
    expect(derivations.length, equals(11));
  });
}
