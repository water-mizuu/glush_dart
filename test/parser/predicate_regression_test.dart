import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Predicate Recursion and Isolation Regressions", () {
    test("Original S = &(S S) S S | 's' repro", () {
      /// Repro grammar for the core predicate exhaustion bug.
      /// S = &(S S) S S | 's'
      var grammar = Grammar(() {
        late final Rule s;
        s = Rule(
          "S",
          () => (And(Seq(s.call(), s.call())) >> s.call() >> s.call()) | Pattern.char("s"),
        );
        return s;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("sss");

      expect(result.success(), isNotNull, reason: "Grammar S = &(S S) S S | 's' should parse 'sss'");
    });

    test("Nested rule-calling predicates", () {
      /// A predicate calling a rule that itself contains another predicate.
      var grammar = Grammar(() {
        late final Rule a;
        late final Rule b;

        // b matches "xy"
        b = Rule("B", () => Pattern.char("x") >> Pattern.char("y"));
        // a matches "x" if "xy" follows
        a = Rule("A", () => And(b.call()) >> Pattern.char("x"));

        // Start matches "xy"
        return Rule("Start", () => And(a.call()) >> a.call() >> Pattern.char("y"));
      });

      var parser = SMParser(grammar);
      var result = parser.parse("xy");

      expect(result.success(), isNotNull, reason: "Nested predicates with rule calls should work");
    });

    test("Negation inside predicate", () {
      /// Ensures that nested negation lookahead resolves correctly.
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");

        // &( ! (a) ) b
        // Matches 'b' only if 'a' does NOT follow (which is always true if we are at 'b')
        // Wait, &( ! (a) ) matches at pos 0 if 'a' doesn't match at 0.
        return Rule("Start", () => And(a.not()) >> b);
      });

      var parser = SMParser(grammar);
      expect(parser.parse("b").success(), isNotNull);
      expect(parser.parse("a").success(), isNull);
    });

    test("Mutually recursive rules inside predicates", () {
      /// Rules calling each other within a lookahead context.
      var grammar = Grammar(() {
        late final Rule a;
        late final Rule b;

        a = Rule("A", () => (Pattern.char("x") >> b.call()) | Pattern.char("x"));
        b = Rule("B", () => (Pattern.char("y") >> a.call()) | Pattern.char("y"));

        // Match "xyx" via predicate lookahead
        return Rule("Start", () => And(a.call()) >> a.call());
      });

      var parser = SMParser(grammar);
      var result = parser.parse("xyx");

      expect(result.success(), isNotNull, reason: "Recursive rules inside lookahead should be stable");
    });

    test("Isolation: Shared caller between main and predicate", () {
      /// Ensures rule calls with different predicate stacks are NOT incorrectly shared.
      var grammar = Grammar(() {
        var x = Pattern.char("x");
        var ruleX = Rule("X", () => x);

        // &(X) X
        // The rule call to X in the predicate should not prevent the main RuleStart from calling X.
        return Rule("Start", () => And(ruleX.call()) >> ruleX.call());
      });

      var parser = SMParser(grammar);
      var result = parser.parse("x");

      expect(result.success(), isNotNull, reason: "Main parse should not be blocked by predicate rule calls");
    });

    test("Deep nesting level of predicates", () {
      /// Ensures predicate stack tracking handles multiple levels of nesting.
      var grammar = Grammar(() {
        return Rule("Start", () => And(And(And(Pattern.char("a")))) >> Pattern.char("a"));
      });

      var parser = SMParser(grammar);
      var result = parser.parse("a");

      expect(result.success(), isNotNull, reason: "Deeply nested predicates should resolve normally");
    });

    test("Predicate failure correctly backtracks", () {
      /// Simple failure case to ensure AND isolation doesn't break basic logic.
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var c = Pattern.char("c");

        // (&(a) b | c)
        return Rule("Start", () => (And(a) >> b) | c);
      });

      var parser = SMParser(grammar);

      // Should fail predicate (no 'a' at start) and match 'c'
      expect(parser.parse("c").success(), isNotNull);
      // Should match predicate but fail sequel (no 'b') and thus fail overall input "ax"
      expect(parser.parse("ax").success(), isNull);
    });
  });
}
