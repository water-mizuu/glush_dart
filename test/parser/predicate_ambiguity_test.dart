import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("Predicates do not multiply branches for ambiguous sub-patterns", () {
    var grammar = Grammar(() {
      var a = Token(const ExactToken(97));
      // Ambiguous sub-pattern inside predicate
      var amb = a | a;
      return Rule("test", () => amb.and() >> a);
    });

    var parser = SMParser(grammar);
    // Use parseAmbiguous to see if we get multiple mark streams
    var outcome = parser.parseAmbiguous("a", captureTokensAsMarks: true);

    expect(outcome, isA<ParseAmbiguousSuccess>());
    var success = outcome as ParseAmbiguousSuccess;

    // We expect only ONE result, because the predicate ambiguity should be collapsed.
    // If we get TWO results, it means the predicate leaked its ambiguity.
    expect(success.forest.allMarkPaths().length, equals(1));
  });

  test("Negative predicates do not multiply branches", () {
    var grammar = Grammar(() {
      var a = Token(const ExactToken(97));
      var b = Token(const ExactToken(98));
      var amb = a | a;
      return Rule("test", () => amb.not() >> b);
    });

    var parser = SMParser(grammar);
    var outcome = parser.parseAmbiguous("b", captureTokensAsMarks: true);

    expect(outcome, isA<ParseAmbiguousSuccess>());
    var success = outcome as ParseAmbiguousSuccess;

    expect(success.forest.allMarkPaths().length, equals(1));
  });
}
