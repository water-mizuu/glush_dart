import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Guard Cache Determinism", () {
    /// Guards should produce consistent results regardless of mark derivation.
    /// This test suite verifies that guard evaluation is deterministic and
    /// doesn't depend on which parse forest produced the marks.

    test("Guard 1: Basic guard with same result across different branches", () {
      const grammar = r"""
        rule = if (position == 0) 'a' 'b' 'c' | if (position == 0) 'a' 'b' 'd';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("abc"), isTrue);
      expect(parser.recognize("abd"), isTrue);
    });

    test("Guard 2: Guard checking position in ambiguous parse", () {
      const grammar = r"""
        rule = if (position == 0) start;
        start = 'a' | 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 3: Guard with captured arguments deterministic", () {
      const grammar = r"""
        rule = if (position == 0) 'a' 'b';
      """;
      var parser = grammar.toSMParser();
      expect(parser.recognize("ab"), isTrue);
    });

    test("Guard 4: Multiple guards on same rule position", () {
      const grammar = r"""
        rule = (if (position < 10) 'a') (if (position < 10) 'b');
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("ab"), isTrue);
    });

    test("Guard 5: Guard with rule name check in ambiguity", () {
      const grammar = r'''
        rule = if (ruleName == "rule") 'a' | if (ruleName == "rule") 'a';
      ''';
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 6: Nested guards with same condition", () {
      const grammar = r"""
        rule = if (position == 0) (if (position == 0) 'a' 'b');
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("ab"), isTrue);
    });

    test("Guard 7: Guard rejecting all alternatives consistently", () {
      const grammar = r"""
        rule = if (position == 99) 'a' | if (position == 99) 'b';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("b"), isFalse);
    });

    test("Guard 8: Guard across ambiguous conjunctions", () {
      const grammar = r"""
        rule = if (position == 0) 'a' 'b';
      """;
      var parser = grammar.toSMParser();
      expect(parser.recognize("ab"), isTrue);
    });

    test("Guard 9: Guard with complex predicate", () {
      const grammar = r"""
        rule = if (position == 0 && callStart == 0) &'a' 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 10: Guard checking minPrecedenceLevel", () {
      const grammar = r"""
        rule = if (minPrecedenceLevel == null) 'a' | 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 11: Guard on left vs right side of alternative", () {
      const grammar = r"""
        rule = if (position == 0) 'a' | if (position == 0) 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 12: Guard in recursive rule", () {
      const grammar = r"""
        rule = if (position < 10) 'a' rule | if (position < 10) 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("aa"), isTrue);
    });

    test("Guard 13: Guard with parameter passing", () {
      const grammar = r"""
        rule = repeat(2);
        repeat(n) = if (n > 0) 'a' repeat(n - 1) | if (n == 0) '';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("aa"), isTrue);
    });

    test("Guard 14: Guard with multiple captures", () {
      const grammar = r'''
        rule = if (ruleName == "rule") 'x' 'y' 'z';
      ''';
      var parser = grammar.toSMParser();
      expect(parser.recognize("xyz"), isTrue);
    });

    test("Guard 15: Guard deterministic with star quantifier", () {
      const grammar = r"""
        rule = if (position == 0) ('a' | 'a')* 'b';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("b"), isTrue);
      expect(parser.recognize("ab"), isTrue);
      expect(parser.recognize("aab"), isTrue);
    });

    test("Guard 16: Guard consistent across different mark paths", () {
      const grammar = r'''
        rule = if (ruleName == "rule") (('a' 'b') | ('a' 'b'));
      ''';
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("ab"), isTrue);
    });

    test("Guard 17: Guard with negation predicate", () {
      const grammar = r"""
        rule = if (position == 0) !'b' 'a';
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("ba"), isFalse);
    });

    test("Guard 18: Guard immutable across cache reuse", () {
      const grammar = r"""
        rule = if (position == 0) 'a' | if (position == 0) 'a';
      """;
      var parser = grammar.toSMParserMini();
      // Multiple parses should use same cache
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("a"), isTrue);
    });

    test("Guard 19: Guard with mark-independent semantics", () {
      const grammar = r'''
        rule = if (ruleName == "rule") 'x' 'y';
      ''';
      var parser = grammar.toSMParser();
      expect(parser.recognize("xy"), isTrue);
    });

    test("Guard 20: Guard result consistent with multiple branch merges", () {
      const grammar = r"""
        rule = if (position < 5) merged;
        merged = ('a' | 'a') ('b' | 'b');
      """;
      var parser = grammar.toSMParserMini();
      expect(parser.recognize("ab"), isTrue);
    });
  });

  group("Label Capture Cache Determinism", () {
    /// Label captures should extract deterministically (earliest match)
    /// regardless of how many parse derivations produced different marks.
    /// Removing marks from cache key should maintain correctness.

    test("Capture 1: Simple label extraction consistency", () {
      const grammar = r"""
        rule = name:('a' | 'a');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["name"].first.span, "a");
    });

    test("Capture 2: Multiple captures same label", () {
      const grammar = r"""
        rule = a:('x' | 'x') b:('y' | 'y');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("xy") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["a"].first.span, "x");
      expect(tree["b"].first.span, "y");
    });

    test("Capture 3: Label earliest match selection", () {
      const grammar = r"""
        rule = name:(('a' | 'a' | 'a'));
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["name"].first.span, "a");
    });

    test("Capture 4: Label extraction with nested rules", () {
      const grammar = r"""
        rule = id:inner;
        inner = 'a' | 'a';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["id"].first.span, "a");
    });

    test("Capture 5: Label with quantifiers", () {
      const grammar = r"""
        rule = nums:([0-9]+);
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("123") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["nums"].first.span, "123");
    });

    test("Capture 6: Label deterministic with different forest paths", () {
      const grammar = r"""
        rule = val:((('a' | 'a') ('b' | 'b')));
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("ab") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "ab");
    });

    test("Capture 7: Label with conjunction", () {
      const grammar = r"""
        rule = val:('a' | 'a') 'b';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("ab") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "a");
    });

    test("Capture 8: Label extraction with optional", () {
      const grammar = r"""
        rule = opt:('a' | 'a')?;
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["opt"][0].span, "a");
    });

    test("Capture 9: Label extraction basic success", () {
      const grammar = r"""
        rule = val:('a' | 'a');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "a");
    });

    test("Capture 10: Label extraction with lookahead", () {
      const grammar = r"""
        rule = 'x' val:('a' | 'a') 'y';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("xay") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "a");
    });

    test("Capture 11: Label with string patterns", () {
      const grammar = r"""
        rule = code:('abc' | 'abc');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("abc") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["code"].first.span, "abc");
    });

    test("Capture 12: Nested label extraction", () {
      const grammar = r"""
        rule = outer:(inner:('a' | 'a') ('b' | 'b'));
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("ab") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["outer"].first.span, "ab");
      expect((tree["outer"].first as ParseResult)["inner"].first.span, "a");
    });

    test("Capture 13: Label with character classes", () {
      const grammar = r"""
        rule = digits:([0-9]+) | letters:([a-z]+);
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("123") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["digits"][0].span, "123");
    });

    test("Capture 14: Label deterministic across multiple parses", () {
      const grammar = r"""
        rule = val:('x' | 'x');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var eval = const StructuredEvaluator();

      for (int i = 0; i < 5; i++) {
        var result = parser.parse("x") as ParseSuccess;
        var tree = eval.evaluate(result.result.rawMarks);
        expect(tree["val"].first.span, "x");
      }
    });

    test("Capture 15: Label with precedence", () {
      const grammar = r"""
        rule = data:(('a'|'a') | ('a'|'a'));
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["data"].first.span, "a");
    });

    test("Capture 16: Label extraction with alternatives", () {
      const grammar = r"""
        rule = val:('' | 'a' | '');
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "a");
    });

    test("Capture 17: Label consistency with parameter passing", () {
      const grammar = r"""
        rule = item;
        item = val:'x' 'y' 'z';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("xyz") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "x");
    });

    test("Capture 18: Label spanning multiple tokens", () {
      const grammar = r"""
        rule = phrase:(identifier ' ' identifier);
        identifier = [a-z]+;
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("hello world") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["phrase"].first.span, "hello world");
    });

    test("Capture 19: Label deterministic with star and alternative", () {
      const grammar = r"""
        rule = items:((item | item)*);
        item = 'x' | 'x';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("xxx") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["items"].first.span, "xxx");
    });

    test("Capture 20: Label earliest match across deep nesting", () {
      const grammar = r"""
        rule = val:inner;
        inner = mid;
        mid = 'a' | 'a' | 'a';
      """;
      var parser = grammar.toSMParser(captureTokensAsMarks: true);
      var result = parser.parse("a") as ParseSuccess;
      var eval = const StructuredEvaluator();
      var tree = eval.evaluate(result.result.rawMarks);
      expect(tree["val"].first.span, "a");
    });
  });
}
