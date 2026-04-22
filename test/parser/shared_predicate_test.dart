import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Shared Predicate Stacks", () {
    test("Deduplicates work under different parallel predicates", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var target = a >> b;

        var ruleA = Rule("A", () => a);
        var ruleB = Rule("B", () => a); // Different rules, but same match pattern
        var ruleTarget = Rule("Target", () => target);

        // &(A) RuleTarget  |  &(B) RuleTarget
        // Since RuleTarget is reached via two different predicate stacks [&A] and [&B],
        // they should be merged into branched([&A], [&B]).
        return Rule("Start", () => (And(ruleA.call()) | And(ruleB.call())) >> ruleTarget.call());
      });

      var parser = SMParser(grammar);
      var result = parser.parse("ab", captureTokensAsMarks: true);

      expect(result.success(), isNotNull);
    });

    test("Nested shared predicates", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");

        var inner = Rule("Inner", () => b);
        var outer1 = Rule("Outer1", () => a >> And(inner.call()));
        var outer2 = Rule("Outer2", () => a >> And(inner.call()));
        var finalRule = Rule("Final", () => a >> b);

        return Rule("Start", () => (And(outer1.call()) | And(outer2.call())) >> finalRule.call());
      });

      var parser = SMParser(grammar);
      var result = parser.parse("ab");

      expect(result.success(), isNotNull);
    });
  });
}
