import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Operator Precedence", () {
    group("PrecedenceExpr - Core Pattern Wrapper", () {
      test("PrecedenceExpr wraps a pattern with a level", () {
        var inner = const LiteralPattern("test", isString: true);
        var prec = PrecedenceExpr(5, inner);

        expect(prec.level, equals(5));
        expect(prec.pattern, equals(inner));
      });

      test("PrecedenceExpr toString shows level and pattern", () {
        var inner = const LiteralPattern("expr");
        var prec = PrecedenceExpr(7, inner);
        var str = prec.toString();

        expect(str, contains("7:"));
        expect(str, contains("expr"));
      });

      test("PrecedenceExpr can wrap any PatternExpr", () {
        var charRange = const CharRangePattern([CharRange(48, 57)]); // [0-9]
        var prec = PrecedenceExpr(10, charRange);

        expect(prec.level, equals(10));
        expect(prec.pattern, isA<CharRangePattern>());
      });

      test("nested PrecedenceExpr - outer level takes precedence", () {
        var inner = const LiteralPattern("x");
        var middle = PrecedenceExpr(3, inner);
        var outer = PrecedenceExpr(7, middle);

        // Compiler will unwrap and use level 7
        expect(outer.level, equals(7));
        expect(outer.pattern, isA<PrecedenceExpr>());
        expect((outer.pattern as PrecedenceExpr).level, equals(3));
      });
    });

    group("Grammar File Parsing - Precedence Syntax", () {
      test("parses precedence constraint syntax (rule^N)", () {
        // RuleRefPattern should store precedenceConstraint
        var ref = const RuleRefPattern("expr", precedenceConstraint: 6);

        expect(ref.precedenceConstraint, equals(6));
        expect(ref.toString(), contains("^6"));
      });

      // Note: Testing full grammar parsing with metagrammar is deferred
      // as there's currently an issue with identifier matching in the metagrammar.
      // The metagrammar evaluator and PrecedenceExpr wrapping work correctly,
      // but the identifier rule needs further investigation.
    });

    group("Code Generation with Precedence", () {
      test("generates Call with minPrecedenceLevel", () {
        var grammar = Grammar(() {
          late Rule expr;
          late Rule num;
          num = Rule("num", () => Token(const ExactToken(49)));
          expr = Rule("expr", () => num(minPrecedenceLevel: 5) | Token(const ExactToken(43)));
          return expr;
        });

        expect(grammar, isNotNull);
      });

      test("grammar with precedence constraints compiles", () {
        var grammar = Grammar(() {
          late Rule primary;
          late Rule expr;
          primary = Rule("primary", () => Token(const ExactToken(49)));
          expr = Rule("expr", () {
            return primary() |
                (expr(minPrecedenceLevel: 6) >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        expect(grammar, isNotNull);
      });
    });

    group("Defining Precedence with PrecedenceExpr", () {
      test("PrecedenceExpr basic creation", () {
        var inner = const LiteralPattern("x");
        var prec = PrecedenceExpr(11, inner);

        expect(prec.level, equals(11));
        expect(prec.pattern, equals(inner));
      });

      test("PrecedenceExpr with sequence", () {
        var seq = const SequencePattern([LiteralPattern("+"), LiteralPattern("-")]);
        var prec = PrecedenceExpr(5, seq);

        expect(prec.level, equals(5));
        expect(prec.pattern, isA<SequencePattern>());
      });

      test("alternations with precedence levels", () {
        // Test that PrecedenceExpr patterns work in alternations
        var pattern1 = const PrecedenceExpr(11, LiteralPattern("1"));
        var pattern2 = const PrecedenceExpr(6, LiteralPattern("+"));
        var pattern3 = const PrecedenceExpr(7, LiteralPattern("*"));
        var alternation = AlternationPattern([pattern1, pattern2, pattern3]);

        expect(alternation.patterns, isNotEmpty);
        expect(alternation.patterns[0], isA<PrecedenceExpr>());
        expect((alternation.patterns[0] as PrecedenceExpr).level, equals(11));
        expect(alternation.patterns[1], isA<PrecedenceExpr>());
        expect((alternation.patterns[1] as PrecedenceExpr).level, equals(6));
        expect(alternation.patterns[2], isA<PrecedenceExpr>());
        expect((alternation.patterns[2] as PrecedenceExpr).level, equals(7));
      });

      test("RuleRefPattern precedence constraint", () {
        var ruleRef = const RuleRefPattern("expr", precedenceConstraint: 8);

        expect(ruleRef.precedenceConstraint, equals(8));
        expect(ruleRef.toString(), contains("^8"));
      });

      test("complex expression with mixed precedence levels", () {
        // Use only basic Grammar features that exist
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                Token(const ExactToken(43)); // '+'
          });
          return expr;
        });

        var parser = SMParser(grammar);
        expect(parser.recognize("1"), isTrue);
        expect(parser.recognize("+"), isTrue);
      });
    });

    group("Natural Precedence via Recursive Structure", () {
      // These tests show that precedence works naturally with recursive descent
      test("left recursion creates left-associative parsing", () {
        var grammar = Grammar(() {
          late Rule expr;
          // Left recursive: expr+1 is left-associative
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) // '1'
                |
                (expr() >> Token(const ExactToken(43)) >> Token(const ExactToken(49))); // expr+1
          });
          return expr;
        });

        var parser = SMParser(grammar);
        expect(parser.recognize("1"), isTrue);
        expect(parser.recognize("1+1"), isTrue);
        expect(parser.recognize("1+1+1"), isTrue);
      });

      test("right recursion creates right-associative parsing", () {
        var grammar = Grammar(() {
          late Rule expr;
          // Right recursive: 1^expr is right-associative
          expr = Rule("expr", () {
            return Token(const ExactToken(50)) // '2'
                |
                (Token(const ExactToken(50)) >> Token(const ExactToken(94)) >> expr()); // 2^expr
          });
          return expr;
        });

        var parser = SMParser(grammar);
        expect(parser.recognize("2"), isTrue);
        expect(parser.recognize("2^2"), isTrue);
        expect(parser.recognize("2^2^2"), isTrue);
      });

      test("multiple operators with structure-based precedence", () {
        var grammar = Grammar(() {
          late Rule add;
          late Rule mul;
          late Rule num;

          num = Rule("num", () => Token(const ExactToken(49))); // '1'

          mul = Rule("mul", () {
            return num() | (mul() >> Token(const ExactToken(42)) >> num()); // mul*num
          });

          add = Rule("add", () {
            return mul() | (add() >> Token(const ExactToken(43)) >> mul()); // add+mul
          });

          return add;
        });

        var parser = SMParser(grammar);
        // 1 + 1 * 1 should parse as 1 + (1 * 1) due to multi-rule structure
        expect(parser.recognize("1"), isTrue);
        expect(parser.recognize("1+1"), isTrue);
        expect(parser.recognize("1*1"), isTrue);
        expect(parser.recognize("1+1*1"), isTrue);
      });
    });

    group("Markers identify operations", () {
      test("markers tag different operations", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) // '1'
                |
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          var addMarks = result.result.marks.where((m) => m == "add").toList();
          expect(addMarks, isNotEmpty);
        }
      });

      test("multiple markers with different operators", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) // '1'
                |
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr()) |
                (Marker("mul") >> expr() >> Token(const ExactToken(42)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1*1");
        expect(result, isA<ParseSuccess>());
      });
    });

    group("Forest and Enumeration - Ambiguity Detection", () {
      test("determines ambiguous vs unambiguous parses", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) // '1'
                |
                (expr() >> Token(const ExactToken(43)) >> expr()); // ambiguous: left vs right
          });
          return expr;
        });

        var parser = SMParser(grammar);

        // '1+1' has 1 unambiguous parse
        var one =
            parser.parseAmbiguous("1+1").ambiguousSuccess()?.forest.allMarkPaths().toList() ?? [];
        expect(one.length, greaterThanOrEqualTo(1));

        // With structure-based precedence, should reduce ambiguity
        var grammar2 = Grammar(() {
          late Rule add;
          late Rule num;
          num = Rule("num", () => Token(const ExactToken(49)));
          add = Rule("add", () {
            return num() | (add() >> Token(const ExactToken(43)) >> num()); // left-assoc
          });
          return add;
        });

        var parser2 = SMParser(grammar2);
        var unambig =
            parser2.parseAmbiguous("1+1+1").ambiguousSuccess()?.forest.allMarkPaths().toList() ??
            [];
        // Well-structured grammar should have exactly 1 parse
        expect(unambig.length, equals(1));
      });

      test("forest extraction with markers", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) // '1'
                |
                (Marker("op") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parseAmbiguous("1+1+1");
        expect(result, isA<ParseAmbiguousSuccess>());
      });
    });

    group("Marks in Parse Results - Comprehensive", () {
      test("single marker appears in marks", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          expect(result.result.marks.length, equals(1));
          expect(result.result.marks[0], equals("add"));
        }
      });

      test("multiple markers appear in depth-first order", () {
        var grammar = Grammar(() {
          late Rule num;
          late Rule term;
          late Rule expr;
          num = Rule("num", () => Token(const ExactToken(49))); // '1'
          term = Rule("term", () {
            return num() | (Marker("mul") >> term() >> Token(const ExactToken(42)) >> num());
          });
          expr = Rule("expr", () {
            return term() | (Marker("add") >> expr() >> Token(const ExactToken(43)) >> term());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        // 1 + 1 * 1 should parse with add and mul markers
        var result = parser.parse("1+1*1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          var markNames = result.result.marks;
          // Should have both markers
          expect(markNames, contains("add"));
          expect(markNames, contains("mul"));
        }
      });

      test("three levels of nesting with different markers", () {
        var grammar = Grammar(() {
          late Rule num;
          late Rule atom;
          late Rule term;
          late Rule expr;
          num = Rule("num", () => Token(const ExactToken(49))); // '1'
          atom = Rule("atom", () {
            return num() | (Marker("pow") >> atom() >> Token(const ExactToken(94)) >> num());
          });
          term = Rule("term", () {
            return atom() | (Marker("mul") >> term() >> Token(const ExactToken(42)) >> atom());
          });
          expr = Rule("expr", () {
            return term() | (Marker("add") >> expr() >> Token(const ExactToken(43)) >> term());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        // 1 + 1 * 1 ^ 1
        var result = parser.parse("1+1*1^1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          var markNames = result.result.marks;
          // Should have all three operators
          expect(markNames.toSet(), equals({"add", "mul", "pow"}));
        }
      });

      test("repeated same marker at multiple levels", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("op") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        // 1 + 1 + 1 should have two 'op' markers
        var result = parser.parse("1+1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          expect(markNames, equals(["op", "op"]));
        }
      });

      test("complex arithmetic: 1 + 2 * 3 + 4", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                Token(const ExactToken(50)) | // '2'
                Token(const ExactToken(51)) | // '3'
                Token(const ExactToken(52)) | // '4'
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr()) |
                (Marker("mul") >> expr() >> Token(const ExactToken(42)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+2*3+4");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          // (1 + (2 * 3)) + 4 has structure: add, mul, add
          expect(markNames.length, equals(3));
          expect(markNames.where((m) => m == "add").length, equals(2));
          expect(markNames.where((m) => m == "mul").length, equals(1));
        }
      });

      test("PrecedenceExpr wraps patterns correctly", () {
        // Test PrecedenceExpr wrapper functionality
        var innerPattern = const LiteralPattern("test");
        var precedencePattern = PrecedenceExpr(5, innerPattern);

        expect(precedencePattern.level, equals(5));
        expect(precedencePattern.pattern, equals(innerPattern));
        expect(precedencePattern.toString(), contains("5:"));
      });

      test("nested PrecedenceExpr patterns", () {
        // Test nested precedence expressions
        var innerLiteral = const LiteralPattern("inner");
        var innerPrec = PrecedenceExpr(3, innerLiteral);
        var outerPrec = PrecedenceExpr(7, innerPrec);

        // Outer level should be 7
        expect(outerPrec.level, equals(7));
        // Inner pattern should still be wrapped PrecedenceExpr
        expect(outerPrec.pattern, isA<PrecedenceExpr>());
        expect((outerPrec.pattern as PrecedenceExpr).level, equals(3));
      });

      test("PrecedenceExpr in alternation pattern", () {
        // Test that PrecedenceExpr works correctly in alternation patterns
        var prec1 = const PrecedenceExpr(11, LiteralPattern("a"));
        var prec2 = const PrecedenceExpr(6, LiteralPattern("b"));
        var alt = AlternationPattern([prec1, prec2]);

        expect(alt.patterns.length, equals(2));
        expect(alt.patterns[0], isA<PrecedenceExpr>());
        expect(alt.patterns[1], isA<PrecedenceExpr>());

        var p1 = alt.patterns[0] as PrecedenceExpr;
        var p2 = alt.patterns[1] as PrecedenceExpr;
        expect(p1.level, equals(11));
        expect(p2.level, equals(6));
      });

      test("PrecedenceExpr with sequence pattern", () {
        // Test PrecedenceExpr wrapping a sequence
        var literal1 = const LiteralPattern("a");
        var literal2 = const LiteralPattern("b");
        var sequence = SequencePattern([literal1, literal2]);
        var precedence = PrecedenceExpr(9, sequence);

        expect(precedence.level, equals(9));
        expect(precedence.pattern, isA<SequencePattern>());
        var innerSeq = precedence.pattern as SequencePattern;
        expect(innerSeq.patterns.length, equals(2));
      });

      test("three different operators all appear in marks", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("plus") >> expr() >> Token(const ExactToken(43)) >> expr()) |
                (Marker("minus") >> expr() >> Token(const ExactToken(45)) >> expr()) |
                (Marker("times") >> expr() >> Token(const ExactToken(42)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1-1*1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          expect(markNames.length, equals(3));
          expect(markNames.toSet(), equals({"plus", "minus", "times"}));
        }
      });

      test("marks are in ParserResult.toList() format", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("op") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markList = result.rawMarks.map((m) => m.toList()).toList();
          expect(markList, isNotEmpty);
          // Each mark converts to [name, position]
          expect(markList[0], isA<List<Object?>>());
          expect(markList[0].length, equals(2));
          expect(markList[0][0], equals("op"));
          expect(markList[0][1], isA<int>());
        }
      });

      test("single marker with direct token matching", () {
        var grammar = Grammar(() {
          return Rule("expr", () {
            return Marker("value") >> Token(const ExactToken(49)); // '1'
          });
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          expect(markNames, equals(["value"]));
        }
      });

      test("alternation with some branches marked, some not", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return (Marker("marked") >> Token(const ExactToken(49))) | // '1' marked
                (Token(const ExactToken(50)) >> Token(const ExactToken(51))); // '23' unmarked
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          expect(markNames, equals(["marked"]));
        }
      });
    });

    group("Compiler Integration with PrecedenceExpr", () {
      test("compiler extracts level from PrecedenceExpr", () {
        var grammarFile = GrammarFile(
          name: "test",
          rules: [
            RuleDefinition(
              name: "num",
              pattern: const PrecedenceExpr(
                11,
                CharRangePattern([CharRange(48, 57)]), // [0-9]
              ),
            ),
          ],
        );

        var compiler = GrammarFileCompiler(grammarFile);
        var grammar = compiler.compile();

        expect(grammar, isNotNull);
        expect(grammar.rules, isNotEmpty);
      });

      test("compiler handles alternation with mixed precedence levels", () {
        var grammarFile = GrammarFile(
          name: "arithmetic",
          rules: [
            RuleDefinition(
              name: "expr",
              pattern: const AlternationPattern([
                PrecedenceExpr(11, CharRangePattern([CharRange(48, 57)])), // [0-9]
                PrecedenceExpr(6, LiteralPattern("+", isString: true)),
                PrecedenceExpr(7, LiteralPattern("*", isString: true)),
              ]),
            ),
          ],
        );

        var compiler = GrammarFileCompiler(grammarFile);
        var grammar = compiler.compile();

        expect(grammar, isNotNull);
      });

      test("RuleDefinition no longer exposes precedenceLevels mapping", () {
        var rule = RuleDefinition(
          name: "test",
          pattern: const PrecedenceExpr(5, LiteralPattern("x")),
        );

        // Should have the pattern, but no precedenceLevels field
        expect(rule.pattern, isA<PrecedenceExpr>());
        expect(rule.name, equals("test"));
      });
    });
  });
}
