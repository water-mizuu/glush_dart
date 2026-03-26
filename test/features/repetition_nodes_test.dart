import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Repetition Node Parsing", () {
    test("parses star and plus as dedicated nodes", () {
      var grammar = GrammarFileParser("""
        start = 'a'* 'b'+ 'c'?;
        """).parse();

      var startRule = grammar.findRule("start");
      expect(startRule, isNotNull);
      var pattern = startRule!.pattern;
      expect(pattern, isA<SequencePattern>());

      var parts = (pattern as SequencePattern).patterns;
      expect(parts.length, equals(3));
      expect(parts[0], isA<StarPattern>());
      expect(parts[1], isA<PlusPattern>());
      expect(parts[2], isA<RepetitionPattern>());
      expect((parts[2] as RepetitionPattern).kind, equals(RepetitionKind.optional));
    });
  });
}
