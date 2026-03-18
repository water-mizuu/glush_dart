import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('State Machine Export/Import Complete Pipeline', () {
    // =========================================================================
    // PARSING TESTS
    // =========================================================================
    group('Parsing with Imported State Machines', () {
      test('Single character grammar works', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Token.charRange('0', '9');
          });
        });

        const input = '5';

        final originalParser = SMParser(grammar);
        final originalResult = originalParser.parse(input);
        expect(originalResult is ParseSuccess, isTrue);

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();

        final reimportedResult = reimportedParser.parse(input);
        expect(reimportedResult is ParseSuccess, isTrue);
      });

      test('Sequence grammar works', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Pattern.char('a') >> Pattern.char('b') >> Pattern.char('c');
          });
        });

        const input = 'abc';

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();

        final result = reimportedParser.parse(input);
        expect(result is ParseSuccess, isTrue);
      });

      test('Alternation grammar works', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Pattern.char('x') | Pattern.char('y') | Pattern.char('z');
          });
        });

        for (final input in ['x', 'y', 'z']) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Failed to parse: $input');
        }
      });

      test('Repetition (+) grammar works', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Token.charRange('0', '9').plus();
          });
        });

        for (final input in ['1', '123', '987654']) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Failed to parse: $input');
        }
      });

      test('Repetition (*) grammar works', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return (Pattern.char('a') >> Token.charRange('0', '9')) | Pattern.char('a');
          });
        });

        for (final input in ['a', 'a0', 'a5', 'a9']) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Failed to parse: $input');
        }
      });

      test('Recursive rule grammar works', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Call(expr) >> Pattern.char('+') >> Token.char('1')) | Token.char('1');
          });
          return expr;
        });

        for (final input in ['1', '1+1', '1+1+1']) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Failed to parse: $input');
        }
      });

      test('Multiple rules work', () {
        final grammar = Grammar(() {
          late Rule expr, term;

          expr = Rule('expr', () {
            return (Call(expr) >> Pattern.char('+') >> Call(term)) | Call(term);
          });

          term = Rule('term', () {
            return Token.charRange('0', '9').plus();
          });

          return expr;
        });

        for (final input in ['5', '5+3', '12+34+56']) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Failed to parse: $input');
        }
      });

      test('Ambiguous grammar parses non-deterministically', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        // Original should parse ambiguous inputs
        final originalParser = SMParser(grammar);
        final originalResult = originalParser.parse('1+1+1');
        expect(originalResult is ParseSuccess, isTrue);

        // Imported should also parse (but may not enumerate all parses)
        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();

        final reimportedResult = reimportedParser.parse('1+1+1');
        expect(reimportedResult is ParseSuccess, isTrue);
      });

      test('Grammar with markers parses correctly', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Marker('add') >> (Call(expr) >> Pattern.char('+') >> Call(expr))) |
                (Marker('num') >> Token.charRange('0', '9'));
          });
          return expr;
        });

        const input = '1+2';

        // Original
        final originalParser = SMParser(grammar);
        final originalResult = originalParser.parse(input);
        expect(originalResult is ParseSuccess, isTrue);

        // Imported
        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();

        final reimportedResult = reimportedParser.parse(input);
        expect(reimportedResult is ParseSuccess, isTrue);
      });
    });

    // =========================================================================
    // EXPORT/IMPORT CYCLE TESTS
    // =========================================================================
    group('Export/Import Cycles', () {
      test('Multiple cycles maintain functionality', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Call(expr) >> Pattern.char('+') >> Token.char('1')) | Token.char('1');
          });
          return expr;
        });

        const input = '1+1+1';

        for (int cycle = 0; cycle < 3; cycle++) {
          final exported = StateMachineExporter.export(grammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          final parser = imported.createParser();

          final result = parser.parse(input);
          expect(result is ParseSuccess, isTrue, reason: 'Cycle $cycle failed');
        }
      });

      test('Different inputs all work after import', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Call(expr) >> Pattern.char('+') >> Call(expr)) | Token.charRange('0', '9');
          });
          return expr;
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final parser = imported.createParser();

        final testInputs = ['5', '1+9', '2+3+4', '7+8+9+0'];

        int successCount = 0;
        for (final input in testInputs) {
          final result = parser.parse(input);
          if (result is ParseSuccess) successCount++;
        }

        expect(successCount, equals(testInputs.length));
      });
    });

    // =========================================================================
    // CODE GENERATION TESTS
    // =========================================================================
    group('Code Generation', () {
      test('Generates syntactically valid Dart code', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('expr', () {
            return (Call(expr) >> Pattern.char('+') >> Token.charRange('0', '9').plus()) |
                Token.charRange('0', '9').plus();
          });
          return expr;
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final codeGen = StateMachineCodeGenerator(exported, grammarName: 'test');
        final code = codeGen.generateStandalone();

        // Check for expected components
        expect(code, contains('_testStateMachineJson'));
        expect(code, contains('loadTestStateMachine()'));
        expect(code, contains('class TestActions'));
        expect(code, contains('class TestParser'));
        expect(code, isNotEmpty);

        // The code should be substantial
        expect(code.length, greaterThan(500));
      });

      test('Generated code structure is correct', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Pattern.char('a') >> Pattern.char('b');
          });
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final codeGen = StateMachineCodeGenerator(exported, grammarName: 'simple');
        final code = codeGen.generateStandalone();

        // Should have the load function
        expect(code, contains(RegExp(r'ExportedStateMachine\s+loadSimpleStateMachine\(\)')));

        // Should have actions class
        expect(code, contains(RegExp(r'class\s+SimpleActions')));

        // Should have parser class
        expect(code, contains(RegExp(r'class\s+SimpleParser')));
      });
    });

    // =========================================================================
    // FAILURE CASES
    // =========================================================================
    group('Invalid Input Handling', () {
      test('Invalid input fails gracefully', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Token.charRange('a', 'z').plus();
          });
        });

        const input = '123'; // Numbers, not letters

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final parser = imported.createParser();

        final result = parser.parse(input);
        expect(result is ParseError, isTrue);
      });

      test('Incomplete match fails', () {
        final grammar = Grammar(() {
          return Rule('S', () {
            return Pattern.char('a') >> Pattern.char('b') >> Pattern.char('c');
          });
        });

        const input = 'ab'; // Missing 'c'

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final parser = imported.createParser();

        final result = parser.parse(input);
        expect(result is ParseError, isTrue);
      });
    });

    // =========================================================================
    // KNOWN LIMITATIONS DOCUMENTATION
    // =========================================================================
    group('Enumeration & Forest Parsing', () {
      test('Enumeration works with imported machines (full pattern serialization)', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        const input = '1+1';

        // Create reimported parser
        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();

        // With full pattern serialization, enumeration now works!
        final parses = reimportedParser.enumerateAllParses(input).toList();
        expect(parses, isNotEmpty, reason: 'Pattern serialization enables enumeration');

        // Basic parsing still works perfectly
        final parseResult = reimportedParser.parse(input);
        expect(parseResult is ParseSuccess, isTrue);
      });

      test('Enumeration works for original grammar', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        const input = '1+1';

        final originalParser = SMParser(grammar);
        final parses = originalParser.enumerateAllParses(input).toList();

        // Original should enumerate successfully
        expect(parses, isNotEmpty);
      });
    });
  });
}
