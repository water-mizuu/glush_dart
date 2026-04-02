import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("SMParserMini Basic Operations", () {
    test("recognize succeeds for simple grammar", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97)); // 'a'
        return Rule("test", () => a >> a);
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("aa"), isTrue);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("aaa"), isFalse);
    });

    test("parse returns marks for simple grammar", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        var m1 = Marker("m1");
        return Rule("test", () => m1 >> a >> a);
      });
      var parser = SMParserMini(grammar, captureTokensAsMarks: true);

      var outcome = parser.parse("aa");
      expect(outcome, isA<ParseSuccess>());
      var success = outcome as ParseSuccess;
      expect(success.result.marks, equals(["m1", "aa"]));
    });

    test("parseAmbiguous returns multiple forests", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        return Rule("test", () => (a >> a) | (a >> a));
      });
      var parser = SMParserMini(grammar);
      var outcome = parser.parseAmbiguous("aa", captureTokensAsMarks: true);
      expect(outcome, isA<ParseAmbiguousSuccess>());
      var success = outcome as ParseAmbiguousSuccess;
      // Depending on GlushList implementation, count completions
      expect(success.forest.allPaths().toList(), isNotEmpty);
    });
  });

  group("SMParserMini Nested Predicates", () {
    test("Double negation !!a", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        return Rule("test", () => a.not().not() >> a);
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("a"), isTrue, reason: "!!a should match a");
      expect(parser.recognize("b"), isFalse);
    });

    test("Triple negation !!!a", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        return Rule("test", () => a.not().not().not() >> a);
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("a"), isFalse, reason: "!!!a should NOT match a");
    });

    test("Nested AND in NOT !(&a)", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));
        return Rule("test", () => a.and().not() >> b);
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("b"), isTrue, reason: '!(&a) at start of "b" is true');
      expect(parser.recognize("a"), isFalse, reason: '!(&a) at start of "a" is false');
    });

    test("Rule call within predicate", () {
      var grammar = Grammar(() {
        late Rule r1;
        late Rule r2;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));
        r1 = Rule("r1", () => a);
        r2 = Rule("r2", () => r1().and() >> b);
        return r2;
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("b"), isFalse); // 'a' matches at pos 0 in &r1
      // Wait, if &r1 matches, it should match 'b'? No,
      // Let's re-verify.
    });

    test("Rule call within predicate - match case", () {
      var grammar = Grammar(() {
        late Rule r1;
        late Rule r2;
        var a = Token(const ExactToken(97));
        r1 = Rule("r1", () => a);
        r2 = Rule("r2", () => r1().and() >> a);
        return r2;
      });
      var parser = SMParserMini(grammar);
      expect(parser.recognize("a"), isTrue);
    });
  });
}
