import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Inline guard conditions (IfCond)", () {
    test("create inline guarded pattern with literal true guard", () {
      // if_(GuardExpr.literal(true), Pattern(...))
      // This creates an inline guarded pattern
      var pattern = if_(GuardExpr.literal(true), Pattern.string("hello"));

      expect(pattern, isA<IfCond>());
    });

    test("inline guard pattern is normalized into synthetic guarded rule", () {
      var grammar = Grammar(() {
        var startRule = Rule("start", () {
          return if_(GuardExpr.literal(true), Pattern.string("test"));
        });
        return startRule;
      });

      // Should have created synthetic guarded rule
      expect(grammar.rules, isNotEmpty);
      // One of the rules should be a guarded synthetic rule with "if$" prefix
      var guardedRules = grammar.rules
          .where((r) => r.guard != null && r.name.symbol.contains(r"if$"))
          .toList();
      expect(
        guardedRules,
        isNotEmpty,
        reason: "Should have created synthetic guarded rule(s) for inline guards",
      );
    });

    test("inline guard in alternation creates multiple guarded rules", () {
      var grammar = Grammar(() {
        var startRule = Rule("start", () {
          return if_(GuardExpr.literal(true), Pattern.string("a")) |
              if_(GuardExpr.literal(false), Pattern.string("b"));
        });
        return startRule;
      });

      var guardedRules = grammar.rules
          .where((r) => r.guard != null && r.name.symbol.contains(r"if$"))
          .toList();
      expect(
        guardedRules.length,
        greaterThanOrEqualTo(2),
        reason: "Should have created guarded rules for each inline guard in alternation",
      );
    });

    test("inline guard with parameter reference in sequence", () {
      var grammar = Grammar(() {
        var startRule = Rule("start", () {
          return Pattern.string("a") >>
              if_(GuardExpr.expression(CallArgumentValue.reference("n")), Pattern.string("b"));
        });
        return startRule;
      });

      var guardedRules = grammar.rules
          .where((r) => r.guard != null && r.name.symbol.contains(r"if$"))
          .toList();
      expect(guardedRules, isNotEmpty);
    });

    test("inline guard compiles and parses correctly with SMParser", () {
      var parser = SMParser(
        Grammar(() {
          var startRule = Rule("start", () {
            // Pattern that always matches if guard is true
            return if_(GuardExpr.literal(true), Pattern.string("hello"));
          });
          return startRule;
        }),
      );

      expect(parser.recognize("hello"), isTrue);
      expect(parser.recognize("world"), isFalse);
    });

    test("inline guard with false literal prevents match", () {
      var parser = SMParser(
        Grammar(() {
          var startRule = Rule("start", () {
            return if_(GuardExpr.literal(false), Pattern.string("hello"));
          });
          return startRule;
        }),
      );

      // Guard is false, so pattern should never match
      expect(parser.recognize("hello"), isFalse);
    });

    test("DSL: simple position-based guard", () {
      const grammarText = r'''
        start = (if (position == 0) '') "hello"
      ''';

      var parser = grammarText.toSMParserMini();
      expect(parser.recognize("hello"), isTrue);
    });

    test("DSL: position-based dispatch in alternation", () {
      const grammarDsl = r'''
        start = (if (position == 0) '') "a"
              | (if (position > 0) '') "b"
      ''';

      var parserDsl = grammarDsl.toSMParserMini();
      expect(parserDsl.recognize("a"), isTrue);
    });

    test("Fluent: alternation with position-based guards", () {
      // Fluent version with position checks (equivalent to DSL version)
      var parserFluent = SMParser(
        Grammar(() {
          return Rule("start", () {
            return if_(
                  GuardExpr.expression(
                    CallArgumentValue.binary(
                      CallArgumentValue.reference("position"),
                      ExpressionBinaryOperator.equals,
                      CallArgumentValue.literal(0),
                    ),
                  ),
                  Pattern.string("a"),
                ) |
                if_(
                  GuardExpr.expression(
                    CallArgumentValue.binary(
                      CallArgumentValue.reference("position"),
                      ExpressionBinaryOperator.greaterThan,
                      CallArgumentValue.literal(0),
                    ),
                  ),
                  Pattern.string("b"),
                );
          });
        }),
      );

      expect(parserFluent.recognize("a"), isTrue);
    });

    test("DSL: inline guard with negation", () {
      const grammarText = r'''
        start = (if (!false) '') "yes"
      ''';

      var parser = grammarText.toSMParserMini();
      expect(parser.recognize("yes"), isTrue);
    });

    test("DSL: guard with captured value length check", () {
      const grammarText = r'''
        start = x:"a" (if (x.length == 1) '') "b"
      ''';

      var parser = grammarText.toSMParser();
      expect(parser.recognize("ab"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("Fluent: sequence with guard on pattern", () {
      var parser = SMParser(
        Grammar(() {
          return Rule("start", () {
            return Label("x", Pattern.string("a")) >>
                if_(GuardExpr.literal(true), Pattern.string("b"));
          });
        }),
      );

      expect(parser.recognize("ab"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("DSL: recursive pattern with guard", () {
      const grammarText = r'''
        start = (if (position < 100) '') content
        content = "data" | sub:start
      ''';

      var parser = grammarText.toSMParserMini();
      expect(parser.recognize("data"), isTrue);
    });
  });
}
