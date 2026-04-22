import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Label Capture Cache Determinism", () {
    /// Label captures should extract deterministically (earliest match)
    /// regardless of how many parse derivations produced different marks.
    /// Removing marks from cache key should maintain correctness.

    test("Capture 1: Simple label extraction consistency", () {
      const grammar = r"""
        rule = name:('a' | 'a');
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["name"].first.span, "a");
    });

    test("Capture 2: Multiple captures same label", () {
      const grammar = r"""
        rule = a:('x' | 'x') b:('y' | 'y');
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("xy", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("xy");
      expect(tree["a"].first.span, "x");
      expect(tree["b"].first.span, "y");
    });

    test("Capture 3: Label earliest match selection", () {
      const grammar = r"""
        rule = name:(('a' | 'a' | 'a'));
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["name"].first.span, "a");
    });

    test("Capture 4: Label extraction with nested rules", () {
      const grammar = r"""
        rule = id:inner;
        inner = 'a' | 'a';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["id"].first.span, "a");
    });

    test("Capture 5: Label with quantifiers", () {
      const grammar = r"""
        rule = nums:([0-9]+);
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("123", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("123");
      expect(tree["nums"].first.span, "123");
    });

    test("Capture 6: Label deterministic with different forest paths", () {
      const grammar = r"""
        rule = val:((('a' | 'a') ('b' | 'b')));
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("ab", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("ab");
      expect(tree["val"].first.span, "ab");
    });

    test("Capture 7: Label with multiple derivations", () {
      const grammar = r"""
        rule = val:('a' | 'a') 'b';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("ab", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("ab");
      expect(tree["val"].first.span, "a");
    });

    test("Capture 8: Label extraction with optional", () {
      const grammar = r"""
        rule = opt:('a' | 'a')?;
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["opt"][0].span, "a");
    });

    test("Capture 9: Label extraction basic success", () {
      const grammar = r"""
        rule = val:('a' | 'a');
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["val"].first.span, "a");
    });

    test("Capture 10: Label extraction with lookahead", () {
      const grammar = r"""
        rule = 'x' val:('a' | 'a') 'y';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("xay", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("xay");
      expect(tree["val"].first.span, "a");
    });

    test("Capture 11: Label with string patterns", () {
      const grammar = r"""
        rule = code:('abc' | 'abc');
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("abc", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("abc");
      expect(tree["code"].first.span, "abc");
    });

    test("Capture 12: Nested label extraction", () {
      const grammar = r"""
        rule = outer:(inner:('a' | 'a') ('b' | 'b'));
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("ab", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("ab");
      expect(tree["outer"].first.span, "ab");
      expect((tree["outer"].first as ParseResult)["inner"].first.span, "a");
    });

    test("Capture 13: Label with character classes", () {
      const grammar = r"""
        rule = digits:([0-9]+) | letters:([a-z]+);
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("123", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("123");
      expect(tree["digits"][0].span, "123");
    });

    test("Capture 14: Label deterministic across multiple parses", () {
      const grammar = r"""
        rule = val:('x' | 'x');
      """;
      var parser = grammar.toSMParser();

      for (int i = 0; i < 5; i++) {
        var result = parser.parse("x", captureTokensAsMarks: true) as ParseSuccess;
        var tree = result.rawMarks.evaluateStructure("x");
        expect(tree["val"].first.span, "x");
      }
    });

    test("Capture 15: Label with precedence", () {
      const grammar = r"""
        rule = data:(('a'|'a') | ('a'|'a'));
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["data"].first.span, "a");
    });

    test("Capture 16: Label extraction with alternatives", () {
      const grammar = r"""
        rule = val:('' | 'a' | '');
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["val"].first.span, "a");
    });

    test("Capture 17: Label consistency with parameter passing", () {
      const grammar = r"""
        rule = item;
        item = val:'x' 'y' 'z';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("xyz", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("xyz");
      expect(tree["val"].first.span, "x");
    });

    test("Capture 18: Label spanning multiple tokens", () {
      const grammar = r"""
        rule = phrase:(identifier ' ' identifier);
        identifier = [a-z]+;
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("hello world", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("hello world");
      expect(tree["phrase"].first.span, "hello world");
    });

    test("Capture 19: Label deterministic with star and alternative", () {
      const grammar = r"""
        rule = items:((item | item)*);
        item = 'x' | 'x';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("xxx", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("xxx");
      expect(tree["items"].first.span, "xxx");
    });

    test("Capture 20: Label earliest match across deep nesting", () {
      const grammar = r"""
        rule = val:inner;
        inner = mid;
        mid = 'a' | 'a' | 'a';
      """;
      var parser = grammar.toSMParser();
      var result = parser.parse("a", captureTokensAsMarks: true) as ParseSuccess;
      var tree = result.rawMarks.evaluateStructure("a");
      expect(tree["val"].first.span, "a");
    });
  });
}
