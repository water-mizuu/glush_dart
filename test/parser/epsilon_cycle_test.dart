import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("Infinite epsilon-label cycles are pruned and do not hang", () {
    var grammar = Grammar(() {
      // ( "x": "" )* "a"
      return Rule("test", () => Label("x", Eps()).star() >> Token(const ExactToken(97)));
    });

    var parser = SMParserMini(grammar);
    
    // This previously caused an infinite loop of unique Context objects.
    // Now it should merge the epsilon iterations and succeed.
    var outcome = parser.parse("a");

    expect(outcome, isA<ParseSuccess>());
  });

  test("Nested epsilon cycles with multiple labels also terminate", () {
    var grammar = Grammar(() {
      // ( "x": ( "y": "" ) )* "a"
      var inner = Label("y", Eps());
      return Rule("test", () => Label("x", inner).star() >> Token(const ExactToken(97)));
    });

    var parser = SMParserMini(grammar);
    var outcome = parser.parse("a");

    expect(outcome, isA<ParseSuccess>());
  });
}
