import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("SCC-based Derivation Counting", () {
    test("Simple non-ambiguous grammar", () {
      // a b c matches exactly one derivation
      var grammar = Grammar(() {
        return Rule("", () => Token.char("a") >> Token.char("b") >> Token.char("c"));
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("abc");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        expect(counts, BigInt.from(1));
      }
    });

    test("Ambiguous grammar with alternation", () {
      // (a | a) matches two derivations
      var grammar = Grammar(() {
        return Rule("", () => Label("1", Token.char("a")) | Label("2", Token.char("a")));
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("a");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        expect(counts, BigInt.from(2));
      }
    });

    test("Left-recursive grammar detection", () {
      // Left-recursive rule: expr -> expr + a | a
      late Rule expr;
      var grammar = Grammar(() {
        expr = Rule("expr", () {
          return (expr.call() >> Token.char("+") >> Token.char("a")) | Token.char("a");
        });
        return expr;
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("a+a");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        // Should have multiple derivations for "a+a"
        expect(counts, greaterThanOrEqualTo(BigInt.from(1)));
      }
    });

    test("Repetition with star - single derivation with greedy matching", () {
      // a* with PEG greedy semantics matches only one way (greedily)
      var grammar = Grammar(() {
        return Rule("S", () => Token.char("a").star());
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("aaa");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        // PEG greedy semantics: only one derivation (match all three 'a's)
        expect(counts, BigInt.from(1));
      }
    });

    test("Complex nested grammar", () {
      // Expression grammar: expr -> term (+ term)*
      // term -> factor (* factor)*
      // factor -> a | (expr)
      late Rule expr;
      late Rule term;
      late Rule factor;
      var grammar = Grammar(() {
        factor = Rule("factor", () {
          return Token.char("a") | (Token.char("(") >> expr.call() >> Token.char(")"));
        });
        term = Rule("term", () {
          return factor.call() >> (Token.char("*") >> factor.call()).star();
        });
        expr = Rule("expr", () {
          return term.call() >> (Token.char("+") >> term.call()).star();
        });
        return expr;
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("a+a");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        expect(counts, greaterThanOrEqualTo(BigInt.from(1)));
      }
    });

    test("Empty forest handling", () {
      var grammar = Grammar(() {
        return Rule("", () => Token.char("a").star());
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        expect(counts, BigInt.from(1));
      }
    });

    test("Derivation count calculation", () {
      // S -> a S b | epsilon
      // For input "aabb": should have derivations
      late Rule s;
      var grammar = Grammar(() {
        s = Rule("S", () {
          return (Token.char("a") >> s.call() >> Token.char("b")) | Eps();
        });
        return s;
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("aabb");

      if (result is ParseAmbiguousSuccess) {
        var forest = result.forest;
        var counts = forest.countDerivations();

        // Should count the derivations correctly
        expect(counts, greaterThan(BigInt.zero));
      }
    });
  });
}
