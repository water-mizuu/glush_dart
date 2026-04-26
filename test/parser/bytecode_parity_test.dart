import "package:glush/glush.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";
import "package:test/test.dart";

void main() {
  group("Bytecode vs SMParser Parity", () {
    void testParity(String name, Grammar grammar, List<String> inputs, {bool isAmbiguous = false}) {
      test(name, () {
        var smParser = SMParser(grammar);
        var bcParser = BCParser(grammar);

        for (var input in inputs) {
          if (isAmbiguous) {
            var smResult = smParser.parseAmbiguous(input);
            var bcResult = bcParser.parseAmbiguous(input);
            expect(
              bcResult.runtimeType,
              equals(smResult.runtimeType),
              reason: "Result type mismatch for input: '$input'",
            );
            if (smResult is ParseAmbiguousSuccess && bcResult is ParseAmbiguousSuccess) {
              // Compare derivation counts if success
              expect(
                bcResult.forest.allMarkPaths().length,
                equals(smResult.forest.allMarkPaths().length),
                reason: "Derivation count mismatch for input: '$input'",
              );
            }
          } else {
            var smSuccess = smParser.recognize(input);
            var bcSuccess = bcParser.recognize(input);
            expect(
              bcSuccess,
              equals(smSuccess),
              reason:
                  "Recognition mismatch for input: '$input'."
                  "\nState Machine yielded: $smSuccess, "
                  "\nBytecode yielded: $bcSuccess",
            );
          }
        }
      });
    }

    group("Basic Features", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => a >> b | a);
      });
      testParity("Simple alternation and sequence", grammar, ["a", "ab", "abc", "b", ""]);
    });

    group("Recursion", () {
      var grammar = Grammar(() {
        late Rule S;
        S = Rule("S", () => Pattern.char("a") >> S.call() | Pattern.char("b"));
        return S;
      });
      testParity("Right recursion", grammar, ["b", "ab", "aab", "aaab", "a", ""]);

      var leftGrammar = Grammar(() {
        late Rule S;
        S = Rule("S", () => S.call() >> Pattern.char("a") | Pattern.char("b"));
        return S;
      });
      testParity("Left recursion", leftGrammar, ["b", "ba", "baa", "baaa", "a", ""]);
    });

    group("Precedence and Associativity", () {
      var grammar = Grammar(() {
        late Rule expr;
        var num = Token(const RangeToken(48, 57));
        var plus = Pattern.char("+");
        var mul = Pattern.char("*");

        expr = Rule(
          "expr",
          () =>
              num.atLevel(10) |
              (expr.call(minPrecedenceLevel: 2) >> mul >> expr.call(minPrecedenceLevel: 3)).atLevel(
                2,
              ) |
              (expr.call(minPrecedenceLevel: 1) >> plus >> expr.call(minPrecedenceLevel: 2))
                  .atLevel(1),
        );
        return expr;
      });
      testParity("Arithmetic precedence", grammar, [
        "1",
        "1+2",
        "1*2",
        "1+2*3",
        "1*2+3",
        "1+2+3",
        "1*2*3",
      ]);
    });

    group("AND Predicates (&)", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => a.and() >> a | b);
      });
      testParity("Positive lookahead", grammar, ["a", "b", "c", "aa"]);
    });

    group("NOT Predicates (!)", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => b.not() >> a | b);
      });
      testParity("Negative lookahead", grammar, ["a", "b", "ba", "c"]);
    });

    group("Nested Predicates", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => (a >> b.not()).and() >> a);
      });
      testParity("AND containing NOT", grammar, ["a", "ab", "b"]);
    });

    group("Ambiguity", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a | a);
      });
      testParity("Simple ambiguity", grammar, ["a"], isAmbiguous: true);

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a >> a | a >> a);
      });
      testParity("Sequence ambiguity", grammar2, ["aa"], isAmbiguous: true);
    });

    group("Retreat", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => a >> b >> Pattern.retreat() >> a);
      });
      testParity("Backtracking/Retreat", grammar, ["a", "ab"]);
    });

    group("Meta-Grammar Subset", () {
      var grammar = Grammar(() {
        var ws = Pattern.char(" ") | Pattern.char("\t") | Pattern.char("\n");
        var comment =
            Pattern.char("#") >>
            (Pattern.char("\n").not() >> Pattern.any()).star() >>
            (Pattern.char("\n") | Eps());
        var whitespace = (ws | comment).star();
        var ident = Token(const RangeToken(97, 122)).plus();
        return Rule("full", () => whitespace >> ident >> whitespace);
      });
      testParity("Whitespace and comments", grammar, [
        "abc",
        "  abc  ",
        "# comment\nabc",
        "abc # trailing",
        " # start\n  abc  # end\n",
      ]);
    });

    // =========================================================================
    // Extended edge-case groups
    // =========================================================================

    group("Epsilon and Optional", () {
      var epsGrammar = Grammar(() {
        return Rule("S", () => Eps());
      });
      testParity("Epsilon matches empty", epsGrammar, ["", "a"]);

      var optGrammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => a.opt() >> b);
      });
      testParity("Optional prefix", optGrammar, ["b", "ab", "aab", "", "a"]);

      var optOnlyGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.opt());
      });
      testParity("Optional only", optOnlyGrammar, ["", "a", "aa"]);
    });

    group("Star and Plus Repetition", () {
      var starGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.star());
      });
      testParity("Star zero-or-more", starGrammar, ["", "a", "aa", "aaa", "b"]);

      var plusGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.plus());
      });
      testParity("Plus one-or-more", plusGrammar, ["", "a", "aa", "aaa", "b"]);

      var mixedGrammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => a.star() >> b.plus());
      });
      testParity("Star then Plus", mixedGrammar, ["b", "ab", "bb", "aab", "abb", "a", ""]);
    });

    group("Boundary Anchors", () {
      var startGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => Pattern.start() >> a);
      });
      testParity("Start-of-input anchor", startGrammar, ["a", "b", ""]);

      var eofGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a >> Pattern.eof());
      });
      testParity("End-of-input anchor", eofGrammar, ["a", "aa", "b", ""]);

      var bothGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => Pattern.start() >> a >> Pattern.eof());
      });
      testParity("Start and EOF anchors", bothGrammar, ["a", "aa", "", "b"]);
    });

    group("Mutual Recursion", () {
      var grammar = Grammar(() {
        late Rule A;
        late Rule B;
        A = Rule("A", () => Pattern.char("a") >> B.call() | Pattern.char("a"));
        B = Rule("B", () => Pattern.char("b") >> A.call() | Pattern.char("b"));
        return A;
      });
      testParity("Mutual recursion A↔B", grammar, ["a", "ab", "aba", "abab", "b", ""]);
    });

    group("NOT Predicate Edge Cases", () {
      var scanGrammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        // Matches 'a' only when NOT preceded-in-lookahead by 'ab' sequence
        return Rule("S", () => (a >> b).not() >> a | b);
      });
      testParity("NOT multi-char lookahead", scanGrammar, ["a", "ab", "b", "c", ""]);

      var eofNotGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.not() >> Pattern.eof() | a);
      });
      testParity("NOT at EOF succeeds", eofNotGrammar, ["", "a", "b"]);
    });

    group("AND Predicate Edge Cases", () {
      var scanGrammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => (a >> b).and() >> a >> b);
      });
      testParity("AND multi-char lookahead", scanGrammar, ["ab", "a", "b", "ac", ""]);

      var doubleAndGrammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.and() >> a.and() >> a);
      });
      testParity("Two consecutive AND predicates", doubleAndGrammar, ["a", "b", ""]);
    });

    group("NOT containing AND (inverse nesting)", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => (a.and() >> b).not() >> (a | b));
      });
      testParity("NOT wrapping AND subpattern", grammar, ["a", "b", "ab", "c", ""]);
    });

    group("Predicate inside Star", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => (b.not() >> a).star() >> b);
      });
      testParity("Star body with NOT predicate", grammar, ["b", "ab", "aab", "aaab", "a", ""]);
    });

    group("Predicate Memoization", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        // Same AND predicate on 'a' fires from both branches at the same position
        return Rule("S", () => a.and() >> a | a.and() >> a >> b);
      });
      testParity("Shared AND predicate across branches", grammar, [
        "a",
        "ab",
        "b",
        "",
      ], isAmbiguous: true);
    });

    group("Predicate inside Recursive Rule", () {
      var grammar = Grammar(() {
        late Rule S;
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        S = Rule("S", () => a.and() >> a >> S.call() | b);
        return S;
      });
      testParity("AND predicate in recursive rule", grammar, ["b", "ab", "aab", "aaab", "a", ""]);
    });

    group("Predicate on Recursive Rule Call", () {
      var grammar = Grammar(() {
        late Rule S;
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        S = Rule("S", () => a >> S.call() | b);
        return Rule("top", () => S.call().and() >> S.call());
      });
      testParity("AND predicate wrapping recursive rule", grammar, ["b", "ab", "aab", "a", ""]);
    });

    group("Mixed Predicates and Alternation", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var c = Pattern.char("c");
        return Rule("S", () => b.not() >> a | b.and() >> b | c);
      });
      testParity("NOT and AND on different branches", grammar, ["a", "b", "c", "d", ""]);
    });

    group("Labels", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("S", () => Label("x", a) >> Label("y", b) | Label("z", a));
      });
      testParity("Labeled captures", grammar, ["a", "ab", "b", "abc", ""]);
    });

    group("Deep Recursion Stress", () {
      var grammar = Grammar(() {
        late Rule S;
        S = Rule("S", () => Pattern.char("a") >> S.call() | Pattern.char("b"));
        return S;
      });
      testParity("Deep right recursion (200 levels)", grammar, ["${"a" * 200}b", "a" * 200]);
    });

    group("Opt-induced Ambiguity", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.opt() >> a.opt());
      });
      testParity("opt>>opt on single 'a' is ambiguous", grammar, [
        "",
        "a",
        "aa",
      ], isAmbiguous: true);
    });

    group("Star Ambiguity", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("S", () => a.star() >> a.star());
      });
      testParity("star>>star ambiguity", grammar, ["", "a", "aa", "aaa"], isAmbiguous: true);
    });

    group("NOT predicate on epsilon rule", () {
      var grammar = Grammar(() {
        var eps = Rule("eps", () => Eps());
        var a = Pattern.char("a");
        return Rule("S", () => eps.call().not() >> a | a >> a);
      });
      testParity("NOT of epsilon rule always fails", grammar, ["", "a", "aa", "b"]);
    });

    group("Complex: JSON-like integers", () {
      var grammar = Grammar(() {
        var digit = Token(const RangeToken(48, 57));
        var nonZero = Token(const RangeToken(49, 57));
        return Rule("integer", () => Pattern.char("0") | nonZero >> digit.star());
      });
      testParity("Integer literals", grammar, ["0", "1", "12", "99", "100", "01", "", "a"]);
    });

    group("Extended Predicate Parity", () {
      group("Deeply Nested NOT", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          // !(!(!a)) >> a | b
          // !(!(!a)) is equivalent to !a
          // So !a >> a | b. For 'a' it fails !a, then b fails.
          // For 'b' it passes !a, matches b.
          return Rule("S", () => a.not().not().not() >> a | b);
        });
        testParity("Triple nested NOT", grammar, ["a", "b", "c", ""]);
      });

      group("Alternating AND/NOT", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          // !(&(a) >> b) >> a
          // &(a) >> b always fails on 'a' because 'b' won't match.
          // So !(...) succeeds on 'a'.
          // Then matches 'a'.
          return Rule("S", () => (a.and() >> b).not() >> a);
        });
        testParity("AND inside NOT with failure", grammar, ["a", "ab", "b", ""]);
      });

      group("Predicate in Star Loop", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          // (!a >> b)*
          // Matches 'b' as long as it's not 'a'.
          return Rule("S", () => (a.not() >> b).star());
        });
        testParity("NOT predicate inside star loop", grammar, ["", "b", "bb", "bbb", "a", "ba"]);
      });

      group("Long Lookahead", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          var c = Pattern.char("c");
          var d = Pattern.char("d");
          // &(abcd) >> a
          return Rule("S", () => (a >> b >> c >> d).and() >> a);
        });
        testParity("Long positive lookahead", grammar, ["abcd", "abc", "abcde", ""]);
      });

      group("Recursive Predicate", () {
        var grammar = Grammar(() {
          late Rule S;
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          // S = &(a >> S | b) >> a | b
          S = Rule("S", () => (a >> S.call() | b).and() >> a | b);
          return S;
        });
        testParity("Predicate wrapping recursive rule", grammar, ["aab", "ab", "b", "aaab", "aaa"]);
      });

      group("Multiple AND Predicates", () {
        var grammar = Grammar(() {
          var a = Pattern.char("a");
          var b = Pattern.char("b");
          var c = Pattern.char("c");
          // &(a) >> &(b) >> c
          // Fails because &(a) and &(b) can't both match at pos 0 unless a==b.
          return Rule("S", () => a.and() >> b.and() >> c);
        });
        testParity("Conflicting AND predicates", grammar, ["a", "b", "c", "abc"]);
      });
    });
  });
}
