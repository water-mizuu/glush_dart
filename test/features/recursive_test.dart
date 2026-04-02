import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Deeply recursive grammars", () {
    test("parses right recursive grammars correctly", () {
      var grammar = Grammar(() {
        late Rule S;
        S = Rule(
          "S",
          () =>
              Token.char("s") | //
              Token.char("s") >> Token.char("+") >> S.call(),
        );

        return S;
      });

      SMParser parser = SMParser(grammar);
      for (int count = 20; count <= 500; count += 20) {
        var input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseAmbiguous(input), isNotNull);
      }
    });

    test("parses left recursive grammars correctly", () {
      var grammar = Grammar(() {
        late Rule S;
        S = Rule(
          "S",
          () =>
              Token.char("s") | //
              S.call() >> Token.char("+") >> Token.char("s"),
        );

        return S;
      });

      var parser = SMParser(grammar);

      for (int count = 20; count <= 500; count += 20) {
        var input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        expect(parser.parseAmbiguous(input), isNotNull);
      }
    });
  });
}
