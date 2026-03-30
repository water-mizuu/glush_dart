import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Star/Plus Unambiguous Behavior", () {
    test("word list with whitespace separators has one parse", () {
      var parser =
          r"""
            start = word (ws+ word)*;
            word = [a-z]+;
            ws = [ \t\n\r];
          """
              .toSMParser();

      const input = "alpha   beta\tgamma\n\tdelta";

      var ambiguous = parser.parseAmbiguous(input);
      expect(ambiguous, isA<ParseAmbiguousSuccess>());
      var paths = (ambiguous as ParseAmbiguousSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      var forest = parser.parseWithForest(input);
      expect(forest, isA<ParseForestSuccess>());
      var trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test("leading/trailing whitespace with token body has one parse", () {
      var parser =
          r"""
            start = ws* body ws*;
            body = [a-z]+;
            ws = [ \t\n\r];
          """
              .toSMParser();

      const input = "   hello_world   ";

      // This input should fail because '_' is not in [a-z], proving we are not
      // silently accepting via ambiguous epsilon/repetition behavior.
      expect(parser.parse(input), isA<ParseError>());

      const validInput = "   helloworld   ";
      var ambiguous = parser.parseAmbiguous(validInput);
      expect(ambiguous, isA<ParseAmbiguousSuccess>());
      var paths = (ambiguous as ParseAmbiguousSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      var forest = parser.parseWithForest(validInput);
      expect(forest, isA<ParseForestSuccess>());
      var trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test("star followed by explicit token remains deterministic for whitespace", () {
      var parser = r"start = [ \t]* 'x';".toSMParser();

      var ambiguous = parser.parseAmbiguous("   \t  x");
      expect(ambiguous, isA<ParseAmbiguousSuccess>());
      var paths = (ambiguous as ParseAmbiguousSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      var forest = parser.parseWithForest("   \t  x");
      expect(forest, isA<ParseForestSuccess>());
      var trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });

    test("plus in token runs is deterministic", () {
      var parser = "start = [a-z]+;".toSMParser();

      var ambiguous = parser.parseAmbiguous("letters");
      expect(ambiguous, isA<ParseAmbiguousSuccess>());
      var paths = (ambiguous as ParseAmbiguousSuccess).forest.allPaths();
      expect(paths.length, equals(1));

      var forest = parser.parseWithForest("letters");
      expect(forest, isA<ParseForestSuccess>());
      var trees = (forest as ParseForestSuccess).forest.extract().toList();
      expect(trees.length, equals(1));
    });
  });
}
