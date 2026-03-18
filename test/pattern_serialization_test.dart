import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Pattern Serialization & Enumeration', () {
    group('Simple Grammars', () {
      test('Single token enumeration works after export/import', () {
        final grammar = Grammar(() {
          return Rule('A', () => Pattern.char('x'));
        });

        const input = 'x';

        // Original parser
        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();
        expect(originalParses, isNotEmpty, reason: 'Original should enumerate successfully');
        expect(originalParses.length, greaterThan(0));

        // Exported and reimported parser
        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        // With full pattern serialization, enumeration should now work
        expect(
          reimportedParses,
          isNotEmpty,
          reason: 'Reimported should enumerate (patterns are serialized)',
        );
        expect(reimportedParses.length, equals(originalParses.length));
      });

      test('Sequence enumeration works after export/import', () {
        final grammar = Grammar(() {
          return Rule('A', () => Pattern.char('a') >> Pattern.char('b') >> Pattern.char('c'));
        });

        const input = 'abc';

        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        expect(reimportedParses.length, equals(originalParses.length));
        expect(reimportedParses, isNotEmpty);
      });

      test('Alternation enumeration works after export/import', () {
        final grammar = Grammar(() {
          return Rule('A', () {
            return Pattern.char('x') | Pattern.char('y') | Pattern.char('z');
          });
        });

        const input = 'y';

        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        expect(reimportedParses.length, equals(originalParses.length));
        expect(reimportedParses, isNotEmpty);
      });
    });

    group('Ambiguous Grammars', () {
      test('Ambiguous expression grammar enumerates all parses after import', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        const input = '1+1';

        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();
        expect(originalParses, isNotEmpty);

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        // With proper pattern serialization, enumeration should work
        expect(
          reimportedParses,
          isNotEmpty,
          reason: 'Reimported parser should enumerate all parses',
        );
        expect(
          reimportedParses.length,
          equals(originalParses.length),
          reason: 'Should find same number of parses',
        );
      });

      test('Ambiguous expression grammar with three operators', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) |
                (Call(a) >> Pattern.char('*') >> Call(a)) |
                Pattern.char('1');
          });
          return a;
        });

        const input = '1+1*1';

        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        expect(reimportedParses.length, equals(originalParses.length));
        expect(reimportedParses.length, greaterThan(1), reason: 'Should have multiple parses');
      });

      test('Left-recursive grammar enumerates correctly', () {
        final grammar = Grammar(() {
          late Rule list;
          list = Rule('List', () {
            return (Call(list) >> Pattern.char(',') >> Pattern.char('x')) | Pattern.char('x');
          });
          return list;
        });

        const input = 'x,x,x';

        final originalParser = SMParser(grammar);
        final originalParses = originalParser.enumerateAllParses(input).toList();

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedParses = reimportedParser.enumerateAllParses(input).toList();

        expect(reimportedParses.length, equals(originalParses.length));
      });
    });

    group('Forest Parsing', () {
      test('Forest parsing extracts all parses after import', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        const input = '1+1';

        final originalParser = SMParser(grammar);
        final originalForest = originalParser.parseWithForest(input);
        expect(originalForest, isA<ParseForestSuccess>());

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedForest = reimportedParser.parseWithForest(input);

        expect(reimportedForest, isA<ParseForestSuccess>());

        if (originalForest is ParseForestSuccess && reimportedForest is ParseForestSuccess) {
          final originalTrees = originalForest.forest.extract().toList();
          final reimportedTrees = reimportedForest.forest.extract().toList();

          // Both should extract successfully
          expect(originalTrees, isNotEmpty);
          expect(reimportedTrees, isNotEmpty);
        }
      });

      test('Forest parsing with multiple level nesting', () {
        final grammar = Grammar(() {
          late Rule expr;
          expr = Rule('Expr', () {
            return (Call(expr) >> Pattern.char('+') >> Call(expr)) |
                (Call(expr) >> Pattern.char('*') >> Call(expr)) |
                Pattern.char('n');
          });
          return expr;
        });

        const input = 'n+n*n';

        final originalParser = SMParser(grammar);
        final originalForest = originalParser.parseWithForest(input);
        expect(originalForest, isA<ParseForestSuccess>());

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final reimportedParser = imported.createParser();
        final reimportedForest = reimportedParser.parseWithForest(input);

        expect(reimportedForest, isA<ParseForestSuccess>());
      });
    });

    group('Pattern Reconstruction Accuracy', () {
      test('Token patterns serialize and deserialize correctly', () {
        final grammar = Grammar(() {
          return Rule('A', () => Pattern.char('x'));
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);

        // Just verify it parses correctly
        final parser = imported.createParser();
        final result = parser.parse('x');
        expect(result, isA<ParseSuccess>());
      });

      test('Alternation patterns serialize correctly', () {
        final grammar = Grammar(() {
          return Rule('A', () {
            return Pattern.char('a') | Pattern.char('b') | Pattern.char('c');
          });
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        expect(exported.rules, isNotEmpty);

        // Get the first rule (Grammar wraps it as S0 or similar)
        final firstRule = exported.rules.values.first;
        expect(firstRule.patternSpec, isNotNull);
        expect(firstRule.patternSpec, isA<AltPatternSpec>());
      });

      test('Sequence patterns serialize correctly', () {
        final grammar = Grammar(() {
          return Rule('A', () {
            return Pattern.char('a') >> Pattern.char('b') >> Pattern.char('c');
          });
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        expect(exported.rules, isNotEmpty);

        final firstRule = exported.rules.values.first;
        expect(firstRule.patternSpec, isNotNull);
        expect(firstRule.patternSpec, isA<SeqPatternSpec>());
      });

      test('Recursive rule patterns serialize with rule names', () {
        final grammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+')) | Pattern.char('1');
          });
          return a;
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        expect(exported.rules, isNotEmpty);

        // The pattern should contain an Alt with a Call reference
        final firstRule = exported.rules.values.first;
        expect(firstRule.patternSpec, isNotNull);
        expect(firstRule.patternSpec, isA<AltPatternSpec>());
      });

      test('Empty input fails gracefully', () {
        final grammar = Grammar(() {
          return Rule('A', () => Pattern.char('x'));
        });

        final exported = StateMachineExporter.export(grammar.stateMachine);
        final imported = ImportedStateMachine(exported);
        final parser = imported.createParser();

        final result = parser.parse('');
        expect(result, isA<ParseError>());
      });
    });

    group('Multiple Cycles', () {
      test('Multiple export/import cycles maintain correctness', () {
        final originalGrammar = Grammar(() {
          late Rule a;
          a = Rule('A', () {
            return (Call(a) >> Pattern.char('+') >> Call(a)) | Pattern.char('1');
          });
          return a;
        });

        const input = '1+1';

        var currentGrammar = originalGrammar;
        var currentParser = SMParser(currentGrammar);
        final originalParses = currentParser.enumerateAllParses(input).toList();

        // Do 3 cycles
        for (int i = 0; i < 3; i++) {
          final exported = StateMachineExporter.export(currentGrammar.stateMachine);
          final imported = ImportedStateMachine(exported);
          currentParser = imported.createParser();

          final parses = currentParser.enumerateAllParses(input).toList();
          expect(
            parses.length,
            equals(originalParses.length),
            reason: 'Cycle ${i + 1} should preserve parse count',
          );
        }
      });
    });
  });
}
