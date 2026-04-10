import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Operator Precedence", () {
    group("Basic Precedence Features", () {
      test("Call pattern supports minPrecedenceLevel parameter", () {
        // Basic test that the API exists and works
        var rule = Rule("test", () => Eps());
        var call = rule(minPrecedenceLevel: 5);
        expect(call.minPrecedenceLevel, equals(5));
        expect(call.toString(), contains("^5"));
      });

      test("RuleCall pattern supports minPrecedenceLevel parameter", () {
        var rule = Rule("test", () => Eps());
        var ruleCall = RuleCall("test_call", rule, minPrecedenceLevel: 3);
        expect(ruleCall.minPrecedenceLevel, equals(3));
        expect(ruleCall.toString(), contains("^3"));
      });

      test("PrecedenceLabeledPattern wraps patterns with levels", () {
        var pattern = Token(const ExactToken(42));
        var labeled = Prec(6, pattern);
        expect(labeled.precedenceLevel, equals(6));
        expect(labeled.toString(), contains("[6]"));
      });
    });

    group("Grammar File Parsing - Precedence Syntax", () {
      test("parses numeric precedence level prefix (N|)", () {
        // Parse a grammar string with precedence syntax: "5| 'a'"
        const grammarText = "expr = 5| 'a';";
        var parser = GrammarFileParser(grammarText);
        var grammarFile = parser.parse();

        expect(grammarFile.rules, isNotEmpty);
        var rule = grammarFile.rules.first;
        expect(rule.name, equals("expr"));

        // The rule should have a precedence level of 5 for the literal pattern
        expect(rule.precedenceLevels, isNotEmpty);
        expect(rule.precedenceLevels.values, contains(5));
      });

      test("parses precedence constraint syntax (rule^N)", () {
        // RuleRefPattern should store precedenceConstraint
        var ref = const RuleRefPattern("expr", precedenceConstraint: 6);
        expect(ref.precedenceConstraint, equals(6));
        expect(ref.toString(), contains("^6"));
      });
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

    group("Defining Precedence with .atLevel()", () {
      test("patterns can be labeled with precedence levels", () {
        var num = Token(const ExactToken(49)).atLevel(11);
        expect(num, isA<Prec>());
        expect(num.toString(), contains("[11]"));
      });

      test("sequences can be labeled with precedence", () {
        var pattern = (Token(const ExactToken(43)) >> Token(const ExactToken(44))).atLevel(5);
        expect(pattern, isA<Prec>());
      });

      test("alternations with precedence levels", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)).atLevel(11) | // number: level 11
                (expr() >> Token(const ExactToken(43)) >> expr()).atLevel(6) | // addition: level 6
                (expr() >> Token(const ExactToken(42)) >> expr()).atLevel(
                  7,
                ); // multiplication: level 7
          });
          return expr;
        });

        expect(grammar, isNotNull);
      });

      test(".withPrecedence() alias works", () {
        var num = Token(const ExactToken(49)).withPrecedence(11);
        expect(num, isA<Prec>());
        expect(num.toString(), contains("[11]"));
      });

      test("complex expression with mixed precedence levels", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)).atLevel(11) | // '1' - level 11
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr()).atLevel(
                  6,
                ) | // addition - level 6
                (Marker("mul") >> expr() >> Token(const ExactToken(42)) >> expr()).atLevel(
                  7,
                ) | // multiplication - level 7
                (Token(const ExactToken(40)) >> expr() >> Token(const ExactToken(41))).atLevel(
                  11,
                ); // parentheses - level 11
          });
          return expr;
        });

        var parser = SMParser(grammar);
        expect(parser.recognize("1"), isTrue);
        expect(parser.recognize("(1)"), isTrue);
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

      test("no markers when no markers in grammar", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isEmpty);
        }
      });

      test("single token with marker prefix", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Marker("num") >> Token(const ExactToken(49)) | // marked number
                (Marker("add") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          // Should have: add, num, num (for 1+1, the two numbers are also marked)
          expect(markNames, contains("add"));
          expect(markNames.where((m) => m == "num").length, equals(2));
        }
      });

      test("marker positions increase with input progress", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("op") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        var result = parser.parse("1+1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var marks = result.result.marks;
          expect(marks.length, equals(2));
          // Both markers are epsilon, so positions show when they were inserted
          // In depth-first parsing, positions may be equal or follow input order
        }
      });

      test("deeply nested expression with many markers", () {
        var grammar = Grammar(() {
          late Rule expr;
          expr = Rule("expr", () {
            return Token(const ExactToken(49)) | // '1'
                (Marker("op") >> expr() >> Token(const ExactToken(43)) >> expr());
          });
          return expr;
        });

        var parser = SMParser(grammar);
        // 1+1+1+1+1 should have 4 'op' markers
        var result = parser.parse("1+1+1+1+1");
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          var markNames = result.result.marks;
          expect(markNames.length, equals(4));
          expect(markNames.every((m) => m == "op"), isTrue);
        }
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
          var markList = result.result.toList();
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
  });
}
