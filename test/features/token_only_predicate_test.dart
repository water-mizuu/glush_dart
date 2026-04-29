import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Token-only predicates optimization", () {
    test("Single token positive lookahead", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var rule = Rule("test", () => a.and() >> a);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: we have 'a' and check passes
      expect(parser.recognize("a"), isTrue);

      // Should fail: we have 'b' (lookahead fails)
      expect(parser.recognize("b"), isFalse);
    });

    test("Single token negative lookahead", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        var rule = Rule("test", () => a.not() >> b);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: first token is not 'a', and we match 'b'
      expect(parser.recognize("b"), isTrue);

      // Should fail: first token is 'a'
      expect(parser.recognize("a"), isFalse);
    });

    test("Token choice (alternation) positive lookahead", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        var rule = Rule("test", () => (a | b).and() >> (a | b));
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: lookahead matches 'a' or 'b', then consume it
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isTrue);

      // Should fail: lookahead doesn't match 'a' or 'b'
      expect(parser.recognize("c"), isFalse);
    });

    test("Token choice negative lookahead", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        var c = Token.char("c");
        var rule = Rule("test", () => (a | b).not() >> c);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: lookahead rejects 'a' or 'b'
      expect(parser.recognize("c"), isTrue);

      // Should fail: lookahead matches 'a' or 'b'
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("b"), isFalse);
    });

    test("Token-only predicate sequence", () {
      var grammar = Grammar(() {
        var a = Token.char("a");
        var b = Token.char("b");
        var rule = Rule("test", () => a.and() >> a >> b.and() >> b);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: both predicates pass
      expect(parser.recognize("ab"), isTrue);

      // Should fail: predicates reject
      expect(parser.recognize("ba"), isFalse);
    });

    test("Token-only predicate with character range", () {
      var grammar = Grammar(() {
        var lowercase = Token.charRange("a", "z");
        var rule = Rule("test", () => lowercase.and() >> lowercase);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: first char is lowercase
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("z"), isTrue);

      // Should fail: first char is not lowercase
      expect(parser.recognize("A"), isFalse);
      expect(parser.recognize("0"), isFalse);
    });

    test("Negative lookahead with character range", () {
      var grammar = Grammar(() {
        var uppercase = Token.charRange("A", "Z");
        var lowercase = Token.charRange("a", "z");
        var rule = Rule("test", () => uppercase.not() >> lowercase);
        return rule;
      });

      var parser = SMParser(grammar);

      // Should succeed: first is not uppercase, consume lowercase
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("z"), isTrue);

      // Should fail: first is uppercase
      expect(parser.recognize("A"), isFalse);
      expect(parser.recognize("Z"), isFalse);
    });
  });
}
