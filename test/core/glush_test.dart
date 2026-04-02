import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Grammar DSL", () {
    test("creates basic grammar", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Eps());
        return rule;
      });

      expect(grammar, isNotNull);
      expect(grammar.startCall, isNotNull);
    });

    test("handles token matching", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () {
          var token = Token(const ExactToken(97)); // "a"
          return token;
        });
        return rule;
      });

      expect(grammar, isNotNull);
    });

    test("grammar-file parser rejects stray top-level tokens", () {
      expect(() => 'start = "a"; }'.toSMParser(), throwsA(isA<GrammarFileParseError>()));
    });

    test("grammar-file parser rejects malformed character ranges", () {
      expect(() => "start = [];".toSMParser(), throwsA(isA<GrammarFileParseError>()));
      expect(() => "start = [z-a];".toSMParser(), throwsA(isA<GrammarFileParseError>()));
    });
  });

  group("Pattern operations", () {
    test("sequence operator works", () {
      var p1 = Token(const ExactToken(97));
      var p2 = Token(const ExactToken(98));
      var seq = p1 >> p2;

      expect(seq, isA<Seq>());
    });

    test("alternation operator works", () {
      var p1 = Token(const ExactToken(97));
      var p2 = Token(const ExactToken(98));
      var alt = p1 | p2;

      expect(alt, isA<Alt>());
    });

    test("repetition works", () {
      var token = Token(const ExactToken(97));
      expect(token.maybe(), isA<Alt>());
    });
  });

  group("SMParser", () {
    test("recognizes balanced parentheses", () {
      Grammar grammar = Grammar(() {
        late Rule expr;
        expr = Rule(
          "expr",
          () => Eps() | (Token(const ExactToken(40)) >> expr() >> Token(const ExactToken(41))),
        );
        return expr;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize(""), isTrue);
      expect(parser.recognize("()"), isTrue);
      expect(parser.recognize("(())"), isTrue);
      expect(parser.recognize("("), isFalse);
      expect(parser.recognize("(()"), isFalse);
    });

    test("recognizes simple patterns", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Token(const ExactToken(97))); // "a"
        return rule;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
      expect(parser.recognize(""), isFalse);
    });

    test("recognizes sequences", () {
      var grammar = Grammar(() {
        var rule = Rule(
          "expr",
          () => Token(const ExactToken(97)) >> Token(const ExactToken(98)),
        ); // ab
        return rule;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("ab"), isTrue);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("ba"), isFalse);
    });

    test("recognizes alternation", () {
      var grammar = Grammar(() {
        var rule = Rule(
          "expr",
          () => Token(const ExactToken(97)) | Token(const ExactToken(98)),
        ); // a or b
        return rule;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isTrue);
      expect(parser.recognize("c"), isFalse);
    });

    test("handles marks", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () {
          return Marker("mark") >> Token(const ExactToken(97));
        });
        return rule;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("a");

      expect(result, isA<ParseSuccess>());
      if (result is ParseSuccess) {
        var parserResult = result.result;
        expect(parserResult.marks, isNotEmpty);
        expect(parserResult.marks[0], "mark");
      }
    });

    test("recognizes start and eof anchors in the Dart DSL", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Pattern.start() >> Pattern.eof());
        return rule;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize(""), isTrue);
      expect(parser.recognize("a"), isFalse);
      expect(parser.parseAmbiguous(""), isA<ParseAmbiguousSuccess>());
    });

    test("grammar-file parser compiles start and eof anchors", () {
      var parser =
          """
        expr = start "a" eof
      """
              .toSMParser();

      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize(""), isFalse);
      expect(parser.recognize("aa"), isFalse);
    });
  });

  group("Error handling", () {
    test("parse error on mismatch", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Token(const ExactToken(97)));
        return rule;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("b");

      expect(result, isA<ParseError>());
      if (result is ParseError) {
        expect(result.position, 0);
      }
    });

    test("parse error at correct position", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () {
          return Token(const ExactToken(97)) >>
              Token(const ExactToken(98)) >>
              Token(const ExactToken(99));
        });
        return rule;
      });

      var parser = SMParser(grammar);
      var result = parser.parse("axx");

      expect(result, isA<ParseError>());
      if (result is ParseError) {
        expect(result.position, 1);
      }
    });
  });
}
