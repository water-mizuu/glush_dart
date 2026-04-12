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

      var parser = SMParser(grammar);
      var outcome = parser.parse("user:michael", captureTokensAsMarks: true);

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
              .toSMParser();

      var outcome = parser.parse("alice:secret", captureTokensAsMarks: true);

      expect(outcome, isA<ParseSuccess>());
      var result = (outcome as ParseSuccess).result;

      var evaluator = const StructuredEvaluator();
      var tree = evaluator.evaluate(result.rawMarks);

      expect(tree["user"].first.span, equals("alice"));
      expect(tree["pass"].first.span, equals("secret"));
    });

    test("Leading dollar labels are namespaced by their rule", () {
      var parser =
          r'''
        start = choice;
        choice = $prec "a"
               | $first "b";
      '''
              .toSMParser();

      var evaluator = const StructuredEvaluator();

      var firstOutcome = parser.parse("a", captureTokensAsMarks: true);
      expect(firstOutcome, isA<ParseSuccess>());
      var firstTree = evaluator.evaluate((firstOutcome as ParseSuccess).result.rawMarks);
      expect(firstTree["choice.prec"].first.span, equals("a"));

      var secondOutcome = parser.parse("b", captureTokensAsMarks: true);
      expect(secondOutcome, isA<ParseSuccess>());
      var secondTree = evaluator.evaluate((secondOutcome as ParseSuccess).result.rawMarks);
      expect(secondTree["choice.first"].first.span, equals("b"));
    });

    test("Nested labels", () {
      var parser =
          '''
        start = person:(first:ident " " last:ident);
        ident = [A-Z][a-z]*;
      '''
              .toSMParser();

      var outcome = parser.parse("John Doe", captureTokensAsMarks: true);

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
