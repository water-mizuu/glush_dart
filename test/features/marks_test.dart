import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Intuitive Marks (Labels)", () {
    test("Labeled patterns produce LabelMarks", () async {
      var grammar = Grammar(() {
        var ident = Token(const RangeToken(97, 122)).plus();
        var rule = Rule("start", () {
          return Label("name", ident) >>
              Token(const ExactToken(58)) >> // :
              Label("value", ident);
        });
        return rule;
      });

      var parser = SMParser(grammar, captureTokensAsMarks: true);
      var outcome = parser.parse("user:michael");

      expect(outcome, isA<ParseSuccess>());
      var result = (outcome as ParseSuccess).result;

      var marks = result.rawMarks;
      var evaluator = const StructuredEvaluator();
      var tree = evaluator.evaluate(marks);

      expect(tree.get("name").first.span, equals("user"));
      expect(tree.get("value").first.span, equals("michael"));
      expect(tree.span, equals("user:michael"));
    });

    test("Grammar string syntax support for labels", () {
      var parser =
          '''
        start = user:ident ":" pass:ident;
        ident = [a-z]+;
      '''
              .toSMParser(captureTokensAsMarks: true);

      var outcome = parser.parse("alice:secret");

      expect(outcome, isA<ParseSuccess>());
      var result = (outcome as ParseSuccess).result;

      var evaluator = const StructuredEvaluator();
      var tree = evaluator.evaluate(result.rawMarks);

      expect(tree["user"].first.span, equals("alice"));
      expect(tree["pass"].first.span, equals("secret"));
    });

    test("Nested labels", () {
      var parser =
          '''
        start = person:(first:ident " " last:ident);
        ident = [A-Z][a-z]*;
      '''
              .toSMParser(captureTokensAsMarks: true);

      var outcome = parser.parse("John Doe");

      expect(outcome, isA<ParseSuccess>());
      var result = (outcome as ParseSuccess).result;

      var evaluator = const StructuredEvaluator();
      var tree = evaluator.evaluate(result.rawMarks);

      var person = tree["person"].first as ParseResult;
      expect(person["first"].first.span, equals("John"));
      expect(person["last"].first.span, equals("Doe"));
      expect(person.span, equals("John Doe"));
    });

    test("Mismatched label nesting fails fast in strict mode", () {
      var evaluator = const StructuredEvaluator();

      expect(
        () => evaluator.evaluateStrict([
          const LabelStartMark("outer", 0),
          const LabelStartMark("inner", 1),
          const LabelEndMark("outer", 0),
          const StringMark("x", 3),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            "message",
            contains('Mismatched label end "outer"'),
          ),
        ),
      );
    });
  });
}
