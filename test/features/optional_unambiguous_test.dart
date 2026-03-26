import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Optional Unambiguous Behavior", () {
    test("optional whitespace around word has one parse", () {
      var parser =
          r"""
            start = ws? word ws?;
            word = [a-z]*;
            ws = [ \t\n\r]*;
          """
              .toSMParser();

      const input = "hello  ";
      var ambiguous = parser.parseAmbiguous(input);
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      var paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      var forest = parser.parseWithForest(input);
      expect(forest, isA<ParseForestSuccess>());
      var trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test("optional delimiter before mandatory delimiter is deterministic", () {
      var parser = "start = ','? ',';".toSMParser();

      var ambiguous = parser.parseAmbiguous(",,");
      expect(ambiguous, isA<ParseAmbiguousForestSuccess>());
      var paths = (ambiguous as ParseAmbiguousForestSuccess).forest.allPaths();
      expect(paths.length, equals(1));
    });

    test("optional branch chooses epsilon only when child does not match", () {
      var parser = "start = [a-z]? 'x';".toSMParser();

      expect(parser.parse("x"), isA<ParseSuccess>());
      expect(parser.parse("ax"), isA<ParseSuccess>());

      var ambiguous1 = parser.parseAmbiguous("x");
      var ambiguous2 = parser.parseAmbiguous("ax");
      expect((ambiguous1 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(1));
      expect((ambiguous2 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(1));
    });
  });
}
