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
      expect(ambiguous, isA<ParseAmbiguousSuccess>());

      var forest = parser.parseAmbiguous(input);
      expect(forest, isA<ParseAmbiguousSuccess>());
    });

    test("optional delimiter before mandatory delimiter is deterministic", () {
      var parser = "start = ','? ',';".toSMParser();

      var ambiguous = parser.parseAmbiguous(",,");
      expect(ambiguous, isA<ParseAmbiguousSuccess>());
    });

    test("optional branch chooses epsilon only when child does not match", () {
      var parser = "start = [a-z]? 'x';".toSMParser();

      expect(parser.parse("x"), isA<ParseSuccess>());
      expect(parser.parse("ax"), isA<ParseSuccess>());

      var ambiguous1 = parser.parseAmbiguous("x");
      var ambiguous2 = parser.parseAmbiguous("ax");
      expect(ambiguous1, isA<ParseAmbiguousSuccess>());
      expect(ambiguous2, isA<ParseAmbiguousSuccess>());
    });
  });
}
