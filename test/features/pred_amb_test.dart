import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Predicate Short-Circuiting", () {
    test("AND with ambiguous sub-pattern succeeds correctly", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97)); // 'a'
        var ambiguous = Rule("ambiguous", () => (Label("a", a)) | (Label("b", a)));
        var r = Rule("test", () => ambiguous.and() >> a);
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);

      // Verification of forest size if applicable
      var forest = parser.parseAmbiguous("a") as ParseAmbiguousSuccess;
      // The overall result for 'test' should only have one derivation path
      // for the 'a' token, because the predicate 'ambiguous.and()'
      // does not contribute to the derivation forest (it's non-consuming).
      var stats = forest.forest.countDerivations();
      expect(stats, BigInt.one);
    });

    test("NOT with ambiguous sub-pattern fails correctly", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97)); // 'a'
        var ambiguous = Rule("ambiguous", () => a | a);
        var r = Rule("test", () => ambiguous.not() >> a);
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
    });

    test("Chained predicates with ambiguity", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));
        var ambA = Rule("ambA", () => a | a);
        var ambB = Rule("ambB", () => b | b);

        return Rule("test", () => ambA.and() >> ambB.not() >> a);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("ab"), isFalse);
    });

    test("Nested predicates short-circuiting", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        var ambA = Rule("ambA", () => a | a);
        var nested = Rule("nested", () => ambA.and().and());

        return Rule("test", () => nested() >> a);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
    });
  });
}
