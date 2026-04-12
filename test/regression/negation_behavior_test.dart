import "package:glush/glush.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:test/test.dart";

void main() {
  group("Negation - Basic Token Behavior", () {
    test("Neg(Token.char('a')) matches non-'a' characters", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      var res = parser.parseAmbiguous("b", captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());
      var success = res as ParseAmbiguousSuccess;
      var paths = success.forest.allMarkPaths().toList();
      expect(paths.length, 1);
      expect(paths.first.evaluateStructure().span, "b");
    });

    test("Neg(Token.char('a')) fails on 'a'", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      var res = parser.parseAmbiguous("a");
      expect(res, isA<ParseError>());
    });

    test("Neg(Token.charRange('0', '9')) matches letters", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.charRange("0", "9"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("x"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("5"), isA<ParseError>());
    });

    test("Neg(Choice of Tokens) matches other letters", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") | Token.char("b") | Token.char("c"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("d"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("a"), isA<ParseError>());
      expect(parser.parseAmbiguous("b"), isA<ParseError>());
      expect(parser.parseAmbiguous("c"), isA<ParseError>());
    });

    test("Negation preserves case sensitivity of inner token", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("A"), isA<ParseAmbiguousSuccess>());
    });

    test("Neg(Token.char) consumes exactly one character on success", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      var res = parser.parseAmbiguous("bc");
      expect(res, isA<ParseError>(), reason: "Whole input 'bc' not matched by single Neg");
    });

    test("Neg(Token.char('a')).plus() matches multiple non-matching characters", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a")).plus()));
      var parser = SMParser(grammar);

      var res = parser.parseAmbiguous("bcd", captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());
      var success = res as ParseAmbiguousSuccess;
      var path = success.forest.allMarkPaths().first.evaluateStructure();
      expect(path.span, "bcd");
    });

    test("Neg(Token.char('a')) fails on empty input (must consume)", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous(""), isA<ParseError>());
    });

    test("Negation with multiple different tokens in sequence", () {
      var grammar = Grammar(() {
        var n = Neg(Token.char("0"));
        return Rule("S", () => n >> n >> n);
      });
      var parser = SMParser(grammar);
      expect(parser.parseAmbiguous("abc"), isA<ParseAmbiguousSuccess>());
    });

    test("Negation on numeric code units charRange", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.charRange("0", "9"))));
      var parser = SMParser(grammar);
      expect(parser.parseAmbiguous("A"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("1"), isA<ParseError>());
    });
  });

  group("Negation - Composition and Repetition", () {
    test("Seq([Token.char('a'), Neg(Token.char('b'))]) works", () {
      var grammar = Grammar(() => Rule("S", () => Token.char("a") >> Neg(Token.char("b"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("ac"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("ab"), isA<ParseError>());
    });

    test("Neg(Token.char('a')).star() matches empty input", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a")).star()));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous(""), isA<ParseAmbiguousSuccess>());
    });

    test("Neg(Token.char('a')).star() matches non-matching sequence", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a")).star()));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("bbb"), isA<ParseAmbiguousSuccess>());
    });

    test("Neg(Token.char('a') | Token.char('b')) complements disjunction", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") | Token.char("b"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("c"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("a"), isA<ParseError>());
      expect(parser.parseAmbiguous("b"), isA<ParseError>());
    });

    test("Neg(Token.char('a') & Token.charRange('a', 'z')) complements conjunction", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") & Token.charRange("a", "z"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("a"), isA<ParseError>());
    });

    test("Neg(Seq([Token.char('a'), Token.char('b')])) fails on 'ab'", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Token.char("b"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("ab"), isA<ParseError>());
    });

    test("Neg(Seq([Token.char('a'), Token.char('b')])) matches non-'ab' of same length", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Token.char("b"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("ac"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("ba"), isA<ParseAmbiguousSuccess>());
    });

    test("Neg(Seq([Token.char('a'), Token.char('b')])) matches other lengths", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Token.char("b"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("abc"), isA<ParseAmbiguousSuccess>());
    });

    test("Choice between positive match and negation", () {
      var grammar = Grammar(() => Rule("S", () => Token.char("a") | Neg(Token.char("a"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
    });

     test("Negation inside a choice that matches different lengths", () {
      var grammar = Grammar(() => Rule("S", () => Token.char("a") | (Neg(Token.char("b")) >> Token.char("c"))));
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("dc"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("bc"), isA<ParseError>());
    });
  });

  group("Negation - Nesting and Double Negation", () {
    test("Neg(Neg(Token.char('a'))) succeeds on 'a' (length 1)", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Neg(Token.char("a")))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
    });

    test("Neg(Neg(Token.char('a'))) fails on 'b' (length 1)", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Neg(Token.char("a")))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("b"), isA<ParseError>());
    });

    test("Neg(Rule reference)", () {
      var grammar = Grammar(() {
        var a = Rule("A", () => Token.char("a"));
        return Rule("S", () => Neg(a.call()));
      });
      var parser = SMParser(grammar);

      expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
      expect(parser.parseAmbiguous("a"), isA<ParseError>());
    });

    test("Negation of a label captures label text if negation finishes", () {
      var grammar = Grammar(() => Rule("S", () => Neg(Label("l", Token.char("a")))));
      var parser = SMParser(grammar);

      var res = parser.parseAmbiguous("b", captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());
      var success = res as ParseAmbiguousSuccess;
      var struct = success.forest.allMarkPaths().first.evaluateStructure();
      expect(struct.get("l"), isEmpty, reason: "Labels from failed negation paths should not be visible");
    });

    test("Double negation with labels", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Neg(Label("l", Token.char("a"))))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
    });

    test("Triple negation", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Neg(Neg(Token.char("a"))))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("a"), isA<ParseError>());
    });

    test("Negation of optional", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a").opt())));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("a"), isA<ParseError>());
       expect(parser.parseAmbiguous(""), isA<ParseError>());
    });

    test("Negation on recursive rule - terminal anchor", () {
       var grammar = Grammar(() {
         late Rule r;
         r = Rule("R", () => Token.char("a") >> r.call() | Token.char("b"));
         return Rule("S", () => Neg(r.call()));
       });
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("b"), isA<ParseError>());
       expect(parser.parseAmbiguous("ab"), isA<ParseError>());
       expect(parser.parseAmbiguous("ax"), isA<ParseAmbiguousSuccess>());
    });

    test("Negation of Negation (large span)", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Neg(Token.char("a") >> Token.char("b")))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("ab"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("ac"), isA<ParseError>());
    });

    test("Negation within conjunction branch", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a")) & Neg(Token.char("b"))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("c"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("a"), isA<ParseError>());
       expect(parser.parseAmbiguous("b"), isA<ParseError>());
    });
  });

  group("Negation - Edge Cases and Robustness", () {
    test("Neg(Eps()) behavior", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Eps())));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous(""), isA<ParseError>());
    });

    test("Negation at end of input", () {
       var grammar = Grammar(() => Rule("S", () => Token.char("a") >> Neg(Token.char("b"))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseError>(), reason: "Neg(b) must consume something");
    });

    test("Negation of cross-boundary Rule", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Token.char("b"))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("abc"), isA<ParseAmbiguousSuccess>());
    });

    test("Ambiguous Negation sub-parse", () {
       var grammar = Grammar(() {
         var a = Token.char("a") | Token.char("a");
         return Rule("S", () => Neg(a));
       });
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseError>());
       expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
    });

    test("Negation of rule with infinite ambiguity", () {
       var grammar = Grammar(() {
         late Rule r;
         r = Rule("R", () => r.call() | Token.char("a"));
         return Rule("S", () => Neg(r.call()));
       });
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("a"), isA<ParseError>());
       expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
    });

    test("Nested negation with overlapping spans", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") >> Neg(Token.char("b")))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("ab"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("ac"), isA<ParseError>());
       expect(parser.parseAmbiguous("xyz"), isA<ParseAmbiguousSuccess>());
    });

    test("Negation of an And lookahead", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a").and())));
       var parser = SMParser(grammar);

       // Neg(And(a)) matches if And(a) doesn't match the span.
       // And(a) is zero-width. Neg(zero-width) only fails at empty input?
       // Actually Neg(p) handles the span [i, j].
       expect(parser.parseAmbiguous("b"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("a"), isA<ParseAmbiguousSuccess>());
    });

    test("Repeated negation and conjunction interplay", () {
       var grammar = Grammar(() => Rule("S", () => (Neg(Token.char("a")) & Token.charRange("a", "z")).plus()));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("bcd"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("abc"), isA<ParseError>());
    });

    test("Negation of a large choice", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("a") | Token.char("b") | Token.char("c") | Token.char("d"))));
       var parser = SMParser(grammar);

       expect(parser.parseAmbiguous("e"), isA<ParseAmbiguousSuccess>());
       expect(parser.parseAmbiguous("a"), isA<ParseError>());
       expect(parser.parseAmbiguous("d"), isA<ParseError>());
    });

    test("Negation leading to successful acceptance with marks", () {
       var grammar = Grammar(() => Rule("S", () => Neg(Token.char("0")).plus()));
       var parser = SMParser(grammar);

       var res = parser.parseAmbiguous("123", captureTokensAsMarks: true);
       expect(res, isA<ParseAmbiguousSuccess>());
       var paths = (res as ParseAmbiguousSuccess).forest.allMarkPaths().toList();
       expect(paths.length, 1);
       var flat = paths.first.evaluateStructure().span;
       expect(flat, "123");
    });
  });
}
