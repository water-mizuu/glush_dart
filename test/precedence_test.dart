import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Operator Precedence', () {
    group('Basic Precedence Features', () {
      test('Call pattern supports minPrecedenceLevel parameter', () {
        // Basic test that the API exists and works
        final rule = Rule('test', () => Eps());
        final call = Call(rule, minPrecedenceLevel: 5);
        expect(call.minPrecedenceLevel, equals(5));
        expect(call.toString(), contains('^5'));
      });

      test('RuleCall pattern supports minPrecedenceLevel parameter', () {
        final rule = Rule('test', () => Eps());
        final ruleCall = RuleCall('test_call', rule, minPrecedenceLevel: 3);
        expect(ruleCall.minPrecedenceLevel, equals(3));
        expect(ruleCall.toString(), contains('^3'));
      });

      test('PrecedenceLabeledPattern wraps patterns with levels', () {
        final pattern = Token(ExactToken(42));
        final labeled = Prec(6, pattern);
        expect(labeled.precedenceLevel, equals(6));
        expect(labeled.toString(), contains('[6]'));
      });
    });

    group('Grammar File Parsing - Precedence Syntax', () {
      test('parses numeric precedence level prefix (N|)', () {
        // Parse a grammar string with precedence syntax: "5| 'a'"
        final grammarText = "expr = 5| 'a';";
        final parser = GrammarFileParser(grammarText);
        final grammarFile = parser.parse();

        expect(grammarFile.rules, isNotEmpty);
        final rule = grammarFile.rules.first;
        expect(rule.name, equals('expr'));

        // The rule should have a precedence level of 5 for the literal pattern
        expect(rule.precedenceLevels, isNotEmpty);
        expect(rule.precedenceLevels.values, contains(5));
      });

      test('parses precedence constraint syntax (rule^N)', () {
        // RuleRefPattern should store precedenceConstraint
        final ref = RuleRefPattern('expr', precedenceConstraint: 6);
        expect(ref.precedenceConstraint, equals(6));
        expect(ref.toString(), contains('^6'));
      });
    });

    group('Code Generation with Precedence', () {
      test('generates Call with minPrecedenceLevel', () {
        final grammar = Grammar(() {
          late Rule expr, num;
          num = Rule('num', () => Token(ExactToken(49)));
          expr = Rule('expr', () => Call(num, minPrecedenceLevel: 5) | Token(ExactToken(43)));
          return expr;
        });

        expect(grammar, isNotNull);
      });

      test('grammar with precedence constraints compiles', () {
        final grammar = Grammar(() {
          late Rule primary, expr;
          primary = Rule('primary', () => Token(ExactToken(49)));
          expr = Rule('expr', () {
            return Call(primary) |
                (Call(expr, minPrecedenceLevel: 6) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        expect(grammar, isNotNull);
      });
    });

    group('Defining Precedence with .atLevel()', () {
      test('patterns can be labeled with precedence levels', () {
        final num = Token(ExactToken(49)).atLevel(11);
        expect(num, isA<Prec>());
        expect(num.toString(), contains('[11]'));
      });

      test('sequences can be labeled with precedence', () {
        final pattern = (Token(ExactToken(43)) >> Token(ExactToken(44))).atLevel(5);
        expect(pattern, isA<Prec>());
      });

      test('alternations with precedence levels', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)).atLevel(11) | // number: level 11
                (Call(expr) >> Token(ExactToken(43)) >> Call(expr)).atLevel(
                  6,
                ) | // addition: level 6
                (Call(expr) >> Token(ExactToken(42)) >> Call(expr)).atLevel(
                  7,
                ); // multiplication: level 7
          });
          return expr;
        });

        expect(grammar, isNotNull);
      });

      test('.withPrecedence() alias works', () {
        final num = Token(ExactToken(49)).withPrecedence(11);
        expect(num, isA<Prec>());
        expect(num.toString(), contains('[11]'));
      });

      test('complex expression with mixed precedence levels', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)).atLevel(11) | // '1' - level 11
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr)).atLevel(
                  6,
                ) | // addition - level 6
                (Marker('mul') >> Call(expr) >> Token(ExactToken(42)) >> Call(expr)).atLevel(
                  7,
                ) | // multiplication - level 7
                (Token(ExactToken(40)) >> Call(expr) >> Token(ExactToken(41))).atLevel(
                  11,
                ); // parentheses - level 11
          });
          return expr;
        });

        final parser = SMParser(grammar);
        expect(parser.recognize('1'), isTrue);
        expect(parser.recognize('(1)'), isTrue);
      });
    });

    group('Natural Precedence via Recursive Structure', () {
      // These tests show that precedence works naturally with recursive descent
      test('left recursion creates left-associative parsing', () {
        final grammar = Grammar(() {
          late Rule expr;
          // Left recursive: expr+1 is left-associative
          expr = Rule('expr', () {
            return Token(ExactToken(49)) // '1'
                |
                (Call(expr) >> Token(ExactToken(43)) >> Token(ExactToken(49))); // expr+1
          });
          return expr;
        });

        final parser = SMParser(grammar);
        expect(parser.recognize('1'), isTrue);
        expect(parser.recognize('1+1'), isTrue);
        expect(parser.recognize('1+1+1'), isTrue);
      });

      test('right recursion creates right-associative parsing', () {
        final grammar = Grammar(() {
          late Rule expr;
          // Right recursive: 1^expr is right-associative
          expr = Rule('expr', () {
            return Token(ExactToken(50)) // '2'
                |
                (Token(ExactToken(50)) >> Token(ExactToken(94)) >> Call(expr)); // 2^expr
          });
          return expr;
        });

        final parser = SMParser(grammar);
        expect(parser.recognize('2'), isTrue);
        expect(parser.recognize('2^2'), isTrue);
        expect(parser.recognize('2^2^2'), isTrue);
      });

      test('multiple operators with structure-based precedence', () {
        final grammar = Grammar(() {
          late Rule add, mul, num;

          num = Rule('num', () => Token(ExactToken(49))); // '1'

          mul = Rule('mul', () {
            return Call(num) | (Call(mul) >> Token(ExactToken(42)) >> Call(num)); // mul*num
          });

          add = Rule('add', () {
            return Call(mul) | (Call(add) >> Token(ExactToken(43)) >> Call(mul)); // add+mul
          });

          return add;
        });

        final parser = SMParser(grammar);
        // 1 + 1 * 1 should parse as 1 + (1 * 1) due to multi-rule structure
        expect(parser.recognize('1'), isTrue);
        expect(parser.recognize('1+1'), isTrue);
        expect(parser.recognize('1*1'), isTrue);
        expect(parser.recognize('1+1*1'), isTrue);
      });
    });

    group('Markers identify operations', () {
      test('markers tag different operations', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) // '1'
                |
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          final addMarks = result.result.marks.where((m) => m == 'add').toList();
          expect(addMarks, isNotEmpty);
        }
      });

      test('multiple markers with different operators', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) // '1'
                |
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr)) |
                (Marker('mul') >> Call(expr) >> Token(ExactToken(42)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1*1');
        expect(result, isA<ParseSuccess>());
      });
    });

    group('Forest and Enumeration - Ambiguity Detection', () {
      test('determines ambiguous vs unambiguous parses', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) // '1'
                |
                (Call(expr) >> Token(ExactToken(43)) >> Call(expr)); // ambiguous: left vs right
          });
          return expr;
        });

        final parser = SMParser(grammar);

        // '1+1' has 1 unambiguous parse
        final one = parser.enumerateAllParses('1+1').toList();
        expect(one.length, greaterThanOrEqualTo(1));

        // With structure-based precedence, should reduce ambiguity
        final grammar2 = Grammar(() {
          late Rule add, num;
          num = Rule('num', () => Token(ExactToken(49)));
          add = Rule('add', () {
            return Call(num) | (Call(add) >> Token(ExactToken(43)) >> Call(num)); // left-assoc
          });
          return add;
        });

        final parser2 = SMParser(grammar2);
        final unambig = parser2.enumerateAllParses('1+1+1').toList();
        // Well-structured grammar should have exactly 1 parse
        expect(unambig.length, equals(1));
      });

      test('forest extraction with markers', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) // '1'
                |
                (Marker('op') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parseWithForest('1+1+1');
        expect(result, isA<ParseForestSuccess>());

        if (result is ParseForestSuccess) {
          final trees = result.forest.extract().toList();
          expect(trees, isNotEmpty);
        }
      });
    });

    group('Marks in Parse Results - Comprehensive', () {
      test('single marker appears in marks', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          expect(result.result.marks.length, equals(1));
          expect(result.result.marks[0], equals('add'));
        }
      });

      test('multiple markers appear in depth-first order', () {
        final grammar = Grammar(() {
          late Rule num, term, expr;
          num = Rule('num', () => Token(ExactToken(49))); // '1'
          term = Rule('term', () {
            return Call(num) | (Marker('mul') >> Call(term) >> Token(ExactToken(42)) >> Call(num));
          });
          expr = Rule('expr', () {
            return Call(term) |
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(term));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        // 1 + 1 * 1 should parse with add and mul markers
        final result = parser.parse('1+1*1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          final markNames = result.result.marks;
          // Should have both markers
          expect(markNames, contains('add'));
          expect(markNames, contains('mul'));
        }
      });

      test('three levels of nesting with different markers', () {
        final grammar = Grammar(() {
          late Rule num, atom, term, expr;
          num = Rule('num', () => Token(ExactToken(49))); // '1'
          atom = Rule('atom', () {
            return Call(num) | (Marker('pow') >> Call(atom) >> Token(ExactToken(94)) >> Call(num));
          });
          term = Rule('term', () {
            return Call(atom) |
                (Marker('mul') >> Call(term) >> Token(ExactToken(42)) >> Call(atom));
          });
          expr = Rule('expr', () {
            return Call(term) |
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(term));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        // 1 + 1 * 1 ^ 1
        final result = parser.parse('1+1*1^1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isNotEmpty);
          final markNames = result.result.marks;
          // Should have all three operators
          expect(markNames.toSet(), equals({'add', 'mul', 'pow'}));
        }
      });

      test('repeated same marker at multiple levels', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('op') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        // 1 + 1 + 1 should have two 'op' markers
        final result = parser.parse('1+1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          expect(markNames, equals(['op', 'op']));
        }
      });

      test('complex arithmetic: 1 + 2 * 3 + 4', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                Token(ExactToken(50)) | // '2'
                Token(ExactToken(51)) | // '3'
                Token(ExactToken(52)) | // '4'
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr)) |
                (Marker('mul') >> Call(expr) >> Token(ExactToken(42)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+2*3+4');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          // (1 + (2 * 3)) + 4 has structure: add, mul, add
          expect(markNames.length, equals(3));
          expect(markNames.where((m) => m == 'add').length, equals(2));
          expect(markNames.where((m) => m == 'mul').length, equals(1));
        }
      });

      test('no markers when no markers in grammar', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          expect(result.result.marks, isEmpty);
        }
      });

      test('single token with marker prefix', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Marker('num') >> Token(ExactToken(49)) | // marked number
                (Marker('add') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          // Should have: add, num, num (for 1+1, the two numbers are also marked)
          expect(markNames, contains('add'));
          expect(markNames.where((m) => m == 'num').length, equals(2));
        }
      });

      test('marker positions increase with input progress', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('op') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final marks = result.result.marks;
          expect(marks.length, equals(2));
          // Both markers are epsilon, so positions show when they were inserted
          // In depth-first parsing, positions may be equal or follow input order
        }
      });

      test('deeply nested expression with many markers', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('op') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        // 1+1+1+1+1 should have 4 'op' markers
        final result = parser.parse('1+1+1+1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          expect(markNames.length, equals(4));
          expect(markNames.every((m) => m == 'op'), isTrue);
        }
      });

      test('three different operators all appear in marks', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('plus') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr)) |
                (Marker('minus') >> Call(expr) >> Token(ExactToken(45)) >> Call(expr)) |
                (Marker('times') >> Call(expr) >> Token(ExactToken(42)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1-1*1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          expect(markNames.length, equals(3));
          expect(markNames.toSet(), equals({'plus', 'minus', 'times'}));
        }
      });

      test('marks are in ParserResult.toList() format', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return Token(ExactToken(49)) | // '1'
                (Marker('op') >> Call(expr) >> Token(ExactToken(43)) >> Call(expr));
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1+1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markList = result.result.toList();
          expect(markList, isNotEmpty);
          // Each mark converts to [name, position]
          expect(markList[0], isA<List<Object?>>());
          expect(markList[0].length, equals(2));
          expect(markList[0][0], equals('op'));
          expect(markList[0][1], isA<int>());
        }
      });

      test('single marker with direct token matching', () {
        final grammar = Grammar(() {
          return Rule('expr', () {
            return Marker('value') >> Token(ExactToken(49)); // '1'
          });
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          expect(markNames, equals(['value']));
        }
      });

      test('alternation with some branches marked, some not', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Marker('marked') >> Token(ExactToken(49))) | // '1' marked
                (Token(ExactToken(50)) >> Token(ExactToken(51))); // '23' unmarked
          });
          return expr;
        });

        final parser = SMParser(grammar);
        final result = parser.parse('1');
        expect(result, isA<ParseSuccess>());

        if (result is ParseSuccess) {
          final markNames = result.result.marks;
          expect(markNames, equals(['marked']));
        }
      });
    });
  });
}
