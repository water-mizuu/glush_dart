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
      expect(parser.parseWithForest(""), isA<ParseForestSuccess>());
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

  group("Enumeration vs Forest Extraction", () {
    /// Helper: extract label from ParseDerivation for structure comparison
    String derivationShape(ParseDerivation d) {
      // Use the symbol ID directly since we don"t have grammar context in tests
      var label = d.symbol;
      if (d.children.isEmpty) {
        return label as String;
      }
      return "$label(${d.children.map(derivationShape).join()})";
    }

    /// Helper: extract label from ParseTree for structure comparison
    String treeShape(ParseTree t) {
      late String label;
      if (t.node is SymbolicNode) {
        label = (t.node as SymbolicNode).symbol as String;
      } else if (t.node is TerminalNode) {
        var token = (t.node as TerminalNode).token;
        label = String.fromCharCode(token);
      } else if (t.node is EpsilonNode) {
        label = "ε";
      } else if (t.node is IntermediateNode) {
        label = (t.node as IntermediateNode).symbol as String;
      } else {
        label = t.node.toString();
      }

      if (t.children.isEmpty) {
        return label;
      }
      return "$label(${t.children.map(treeShape).join('","')})";
    }

    test("counts match for simple unambiguous grammar", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Token(const ExactToken(97))); // "a"
        return rule;
      });

      var parser = SMParser(grammar);
      var derivations = parser.enumerateAllParses("a").toList();

      var forestResult = parser.parseWithForest("a");
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1));
      }
    });

    test("counts match for simple ambiguous grammar S->SS|ε", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () => Eps() | (s() >> s()));
        return s;
      });

      var parser = SMParser(grammar);
      const testInput = "";
      var derivations = parser.enumerateAllParses(testInput).toList();

      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1)); // ε produces exactly one parse
      }
    });

    test("counts match for ambiguous grammar with input", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () => Eps() | (Token(const ExactToken(97)) >> s() >> s()));
        return s;
      });

      var parser = SMParser(grammar);
      const testInput = "a";
      var derivations = parser.enumerateAllParses(testInput).toList();

      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test("tree structures match for S->SS|s grammar", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () {
          return Token(const ExactToken(115)) | (s() >> s()); // s | SS
        });
        return s;
      });

      var parser = SMParser(grammar);
      const testInput = "ss";
      var derivations = parser.enumerateAllParses(testInput).toList();

      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();

        // Both should find the same number of parses
        expect(derivations.length, equals(trees.length));

        // Get tree shapes from both approaches
        var derivShapes = derivations.map(derivationShape).toSet();
        var treeShapes = trees.map(treeShape).toSet();

        // Both should have the same structural representations
        expect(derivShapes.length, equals(treeShapes.length));
      }
    });

    test("counts match for left-recursive grammar", () {
      var grammar = Grammar(() {
        late Rule expr;
        expr = Rule("expr", () {
          return Token(const ExactToken(97)) // a
              |
              (expr() >> Token(const ExactToken(43)) >> expr()); // expr+expr
        });
        return expr;
      });

      var parser = SMParser(grammar);
      const testInput = "a+a";
      var derivations = parser.enumerateAllParses(testInput).toList();

      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test("counts match for nested alternation", () {
      var grammar = Grammar(() {
        late Rule a;
        late Rule b;
        a = Rule("A", () {
          return (Token(const ExactToken(97)) >> b()) | Eps();
        });
        b = Rule("B", () {
          return (Token(const ExactToken(98)) >> a()) | Eps();
        });
        return a;
      });

      var parser = SMParser(grammar);
      const testInput = "ab";
      var derivations = parser.enumerateAllParses(testInput).toList();

      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
      }
    });

    test("empty parse produces same count for both", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Eps());
        return rule;
      });

      var parser = SMParser(grammar);
      var derivations = parser.enumerateAllParses("").toList();

      var forestResult = parser.parseWithForest("");
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(1));
      }
    });

    test("both fail gracefully on non-matching input", () {
      var grammar = Grammar(() {
        var rule = Rule("expr", () => Token(const ExactToken(97))); // "a"
        return rule;
      });

      var parser = SMParser(grammar);
      var derivations = parser.enumerateAllParses("b").toList();

      var forestResult = parser.parseWithForest("b");
      expect(forestResult, isA<ParseError>());

      // Both should have no parses for invalid input
      expect(derivations.length, equals(0));
    });

    test("counts match for more complex ambiguity S->SSS|SS|s", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule(
          "S",
          () =>
              Token.char("s") | // s
              (Marker("") >> s() >> s()).withAction((_, c) => [...c]) | // SS
              (Marker("") >> s() >> s() >> s()).withAction((_, c) => [...c]) |
              (Marker("") >> s() >> s() >> s() >> s()).withAction((_, c) => [...c]), // SSS
        );
        return s;
      });

      var parser = SMParser(grammar);
      const testInput = "sssss";
      var derivationCount = parser.countAllParses(testInput);
      var derivations = parser.enumerateAllParses(testInput).toList();
      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        var trees = forestResult.forest.extract().toList();
        Set<String> enumerations =
            derivations //
                .map((s) => s.toPrecedenceString(testInput))
                .toSet();
        Set<String> forestExtracted = forestResult.forest
            .extract()
            .map((s) => s.toPrecedenceString(testInput))
            .toSet();

        expect(enumerations, equals(forestExtracted));
        expect(forestExtracted, equals(enumerations));
        expect(enumerations.difference(forestExtracted), equals(<String>{}));
        expect(forestExtracted.difference(enumerations), equals(<String>{}));
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(derivationCount));
        expect(derivations.length, equals(44));
      }
    });

    test("counts match for more complex ambiguity cleanly S->SSS|SS|s", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () {
          return Token.char("s") | // s
              (s() >> s()) | // SS
              (s() >> s() >> s()) |
              (s() >> s() >> s() >> s()); // SSS
        });
        return s;
      });

      var parser = SMParser(grammar);
      const testInput = "sssss";
      var derivationCount = parser.countAllParses(testInput);
      var derivations = parser.enumerateAllParses(testInput).toList();
      var forestResult = parser.parseWithForest(testInput);
      expect(forestResult, isA<ParseForestSuccess>());

      if (forestResult is ParseForestSuccess) {
        Set<String> enumerations =
            derivations //
                .map((s) => s.toPrecedenceString(testInput))
                .toSet();
        Set<String> forestExtracted = forestResult.forest
            .extract()
            .map((s) => s.toPrecedenceString(testInput))
            .toSet();

        var trees = forestResult.forest.extract().toList();
        expect(enumerations, equals(forestExtracted));
        expect(forestExtracted, equals(enumerations));
        expect(enumerations.difference(forestExtracted), equals(<String>{}));
        expect(forestExtracted.difference(enumerations), equals(<String>{}));
        expect(derivations.length, equals(trees.length));
        expect(derivations.length, equals(derivationCount));
        expect(derivations.length, equals(44));
      }
    });
  });
}
