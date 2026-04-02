import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("AND Predicates (&)", () {
    test("AND succeeds when pattern matches", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          return a.and() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("AND prevents matching when pattern doesnt match", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return b.and() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("b"), isFalse);
    });

    test("AND doesnt consume input", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var b = Token(const ExactToken(98));
          return b.and() >> b;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("b"), isTrue);
      expect(parser.recognize("a"), isFalse);
    });

    test("AND with rule calls", () {
      var grammar = Grammar(() {
        late Rule expr;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));

        expr = Rule("expr", () => a | (b.and() >> a));
        return expr;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });
  });

  group("NOT Predicates (!)", () {
    test("NOT succeeds when pattern fails", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("NOT prevents matching when pattern matches", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          return a.not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("b"), isFalse);
    });

    test("NOT doesnt consume input", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return a.not() >> b;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("b"), isTrue);
      expect(parser.recognize("a"), isFalse);
    });

    test("NOT with alternation", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return (b | c).not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
      expect(parser.recognize("c"), isFalse);
    });

    test("Double negation", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return b.not().not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("b"), isFalse);
    });

    test("NOT in rule calls", () {
      var grammar = Grammar(() {
        late Rule expr;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));

        expr = Rule("expr", () => a | (b.not() >> a));
        return expr;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
    });

    test("NOT at end of input", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return a >> b.not();
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("ab"), isFalse);
    });
  });

  group("Combined AND/NOT patterns", () {
    test("AND with sequence lookahead", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return (b >> c).and() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
    });

    test("NOT with sequence lookahead", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return (b >> c).not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
      expect(parser.recognize("abc"), isFalse);
    });

    test("Multiple predicates in sequence", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return a >> b.and() >> c.not() >> b;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("ab"), isTrue);
      expect(parser.recognize("abc"), isFalse);
    });

    test("Predicate in alternation", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return (a >> b.and()) | c;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("c"), isTrue);
      expect(parser.recognize("a"), isFalse);
    });

    test("Lookahead in left-recursive rule", () {
      var grammar = Grammar(() {
        late Rule expr;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));

        expr = Rule("expr", () => b.not() >> a | expr() >> a);
        return expr;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("aa"), isTrue);
      expect(parser.recognize("aaa"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });
  });

  group("Predicate edge cases", () {
    test("Predicate with epsilon", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          return Eps().and() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("Negation of epsilon", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          return Eps().not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
    });

    test("Complex alternation in lookahead", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          var d = Token(const ExactToken(100));
          return (b | c | d).and() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
    });
  });

  group("Predicate with semantic actions", () {
    test("Predicate followed by semantic action", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return (b.not() >> a).withAction((span, _) => "matched_$span");
        });
        return r;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("a");
      expect(result, isA<ParseSuccess>());
    });
  });

  group("Predicate performance - no backtracking", () {
    test("Lookahead doesnt consume on failure", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          var c = Token(const ExactToken(99));
          return (b.and() >> a) | c;
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("c"), isTrue);
    });
  });

  group("Integration with forest and enumeration", () {
    test("Predicate with forest parsing", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      var result = parser.parseAmbiguous("a");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Predicate with enumeration", () {
      var grammar = Grammar(() {
        var r = Rule("test", () {
          var a = Token(const ExactToken(97));
          var b = Token(const ExactToken(98));
          return b.not() >> a;
        });
        return r;
      });

      var parser = SMParser(grammar);
      var derivations = parser.parseAmbiguous("a").ambiguousSuccess()?.forest.allPaths().toList();
      expect(derivations, isNotEmpty);
    });
  });

  group("Advanced predicate scenarios", () {
    test("Keyword recognition with negative lookahead", () {
      var grammar = Grammar(() {
        var r = Rule("keyword", () {
          var w = Token(const ExactToken(119));
          var h = Token(const ExactToken(104));
          var i = Token(const ExactToken(105));
          var l = Token(const ExactToken(108));
          var e = Token(const ExactToken(101));
          var letter = Token(const RangeToken(97, 122));

          return (w >> h >> i >> l >> e) >> letter.not();
        });
        return r;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("while"), isTrue);
    });

    test("Multiple predicates chained", () {
      var grammar = Grammar(() {
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));
        return Rule("test", () => a.and() >> b.not() >> a);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("ba"), isFalse);
      expect(parser.recognize("abc"), isFalse);
    });

    test("Predicate in deeply nested rules", () {
      var grammar = Grammar(() {
        late Rule e1;
        late Rule e2;
        late Rule e3;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));

        e1 = Rule("e1", () => a | e2());
        e2 = Rule("e2", () => b.not() >> e3());
        e3 = Rule("e3", () => a);

        return e1;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
    });
  });
}
