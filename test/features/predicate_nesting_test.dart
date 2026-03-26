import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Complex Predicate Combinations", () {
    test("Lookahead for NOT: &(!a) b", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        return Rule("test", () => a.not().and() >> b);
      });
      var parser = SMParser(grammar);
      expect(parser.recognize("b"), isTrue, reason: '&(!a) b should match "b"');
      expect(parser.recognize("a"), isFalse, reason: '&(!a) b should NOT match "a"');
    });

    test("Negative lookahead for AND: !(&a b) a", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        return Rule("test", () => (a.and() >> b).not() >> a);
      });
      var parser = SMParser(grammar);
      // !(&a b) a matches 'a' only if NOT (&a b).
      // On input 'a':
      // sub-parse &a b: matches 'a', then fails because 'b' is missing.
      // So &a b fails.
      // So !(&a b) succeeds.
      // Then match 'a'.
      expect(
        parser.recognize("a"),
        isTrue,
        reason: '!(&a b) a should match "a" while "b" is missing',
      );

      // On input 'ab': recognize matches the WHOLE input.
      // Final rule: !(&a b) a.
      // &a b matches 'ab' at pos 0?
      // &a b(0): &a matches 'a' at 0. then 'b' matches at 1.
      // So &a b succeeds.
      // So !(&a b) fails.
      expect(parser.recognize("ab"), isFalse, reason: '!(&a b) a should fail on "ab"');
    });

    test("Nested alternatives in lookahead: &(&a | &b) (a | b)", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        return Rule("test", () => (a.and() | b.and()).and() >> (a | b));
      });
      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isTrue);
      expect(parser.recognize("c"), isFalse);
    });

    test("Complex double-negated AND with sequence: !!(&a >> !b) a", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        return Rule("test", () => (a.and() >> b.not()).not().not() >> a);
      });
      var parser = SMParser(grammar);
      // !!(&a >> !b) a
      // Inner: &a >> !b. Succeeds if 'a' is there and NOT followed by 'b'.
      // If input is 'a' (end of string): &a matches, !b matches (empty after a). Succeeds.
      // So !!(success) succeeds.
      expect(parser.recognize("a"), isTrue, reason: '"a" is "a followed by NOT b"');

      // If input is 'ab':
      // &a matches 'a' at 0. !b(1) fails because 'b' is there.
      // So (&a >> !b) fails.
      // So !!(fail) fails.
      expect(parser.recognize("ab"), isFalse, reason: '"ab" is NOT "a followed by NOT b"');
    });

    test("Multiple predicates at same position", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        // S = &a !b a
        return Rule("S", () => a.and() >> b.not() >> a);
      });
      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("ab"), isFalse);
    });

    test("Deeply nested NOTs with sequence matching: !(!(!a b) c) d", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        var c = Token.char("c");
        var d = Token.char("d");
        return Rule("test", () => ((a >> b).not().not() >> c).not() >> d);
      });
      var parser = SMParser(grammar);
      expect(parser.recognize("d"), isTrue, reason: '"abc" does not start, "d" is there');
      expect(
        parser.recognize("abcd"),
        isFalse,
        reason: '"abc" starts at 0, so !("abc" starting) fails',
      );
    });
  });

  group("Recursive Predicates", () {
    test('Recursive rule inside lookahead: &Parens "(("', () {
      var grammar = Grammar(() {
        late Rule parens;
        parens = Rule(
          "Parens",
          () => (Token.char("(") >> parens.call() >> Token.char(")")).maybe(),
        );
        return Rule("test", () => parens.call().and() >> Token.char("(").plus());
      });
      var parser = SMParser(grammar);

      // Parens matches "", "()", "(())", etc.
      // S = &Parens '('+
      // On "((": &Parens can match "" at pos 0. So it succeeds. Then matches "((".
      expect(parser.recognize("(("), isTrue);

      // On "(()": &Parens matched "()". Then remaining is "(". But recognize wants WHOLE input?
      // Wait, recognize('(()'): &Parens matches at 0. But it doesn't consume.
      // Then '('+ must match "(()". It doesn't.
      expect(parser.recognize("(()"), isFalse);
    });

    test('Negative lookahead for recursive rule: !Balanced "aa"', () {
      var grammar = Grammar(() {
        late Rule balanced;
        balanced = Rule(
          "Balanced",
          () => (Token.char("a") >> balanced.call() >> Token.char("b")).maybe(),
        );
        // Simple grammar: !Balanced matches if not 'a'*n 'b'*n
        return Rule("test", () => balanced.call().not() >> Token.char("a").plus());
      });
      var parser = SMParser(grammar);

      // On "aa": Balanced matches "" (ε). So !Balanced fails.
      // Wait, Balanced matches ε at pos 0. So !Balanced fails.
      // So "aa" should fail.
      expect(parser.recognize("aa"), isFalse);

      // Wait! Balanced matches ε. If input is "aa", Balanced DOES match ε.
      // If Balanced matches anything at that position, !Balanced fails.
      // Since it matches ε, it always fails at any position?
      // YES. A NOT predicate for an ε-rule always fails.
    });

    test("Mutual recursion between rule and predicate", () {
      // S = 'a' &S S| 'b'
      // This is a bit weird but valid.
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () => (Token.char("a") >> s.call().and() >> s.call()) | Token.char("b"));
        return s;
      });
      var parser = SMParser(grammar);

      // Input "ab":
      // S(0): matches 'a'. then &S(1). S(1) matches 'b'. So &S succeeds.
      // Then S(1) matches 'b'.
      // Success.
      expect(parser.recognize("ab"), isTrue);

      // Input "aab":
      // S(0): 'a'. &S(1).
      // S(1): 'a'. &S(2). S(2) matches 'b'. Success.
      // S(1) matches 'ab'. Success.
      // S(0) matches 'aab'. Success.
      expect(parser.recognize("aab"), isTrue);

      expect(parser.recognize("aa"), isFalse);
    });
  });
}
