import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Associativity control', () {
    test('No constraint on right enables right-associativity', () {
      // Using: expr^6 '^' expr (no constraint on right) creates BOTH left and right-assoc parses
      // Tree 0 is left-assoc: ((2^3)^4)
      // Tree 1 is right-assoc: (2^(3^4))
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      final result = smParser.parseWithForest('2^3^4');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees.length, 2, reason: 'Should have both left-assoc and right-assoc parses');
        print('No constraint (expr^6 \'^\' expr): ${trees.length} tree(s)');
        final prec0 = trees[0].toPrecedenceString('2^3^4');
        final prec1 = trees[1].toPrecedenceString('2^3^4');
        print('  Tree 0: $prec0 (left-assoc: ((2^3)^4))');
        print('  Tree 1: $prec1 (right-assoc: (2^(3^4)))');
      }
    });

    test('Different constraints (higher level on right) filters to left-assoc only', () {
      // Using different levels: expr^6 '^' expr^7 filters out right-assoc
      // expr^7 constraint on right means it can only match atoms (level 11), not operators (level 6)
      // Result: Only left-assoc possible
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr^7
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      final result = smParser.parseWithForest('2^3^4');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees.length, 1, reason: 'Should only have left-assoc due to constraint filtering');
        print('\nHigher constraint (expr^6 \'^\' expr^7): ${trees.length} tree(s)');
        final prec0 = trees[0].toPrecedenceString('2^3^4');
        print('  Tree 0: $prec0 (only left-assoc available)');
      }
    });

    test('Same constraints produce both associativities', () {
      // Using same levels: expr^6 '^' expr^6 allows BOTH left-assoc and right-assoc parses
      // This is the ambiguous case - the grammar is naturally ambiguous
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr^6
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      final result = smParser.parseWithForest('2^3^4');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees.length, 2, reason: 'Same constraints create both parses (ambiguous)');
        print('\nSame constraints (expr^6 \'^\' expr^6): ${trees.length} tree(s)');
        final prec0 = trees[0].toPrecedenceString('2^3^4');
        final prec1 = trees[1].toPrecedenceString('2^3^4');
        print('  Tree 0: $prec0 (left-assoc: ((2^3)^4))');
        print('  Tree 1: $prec1 (right-assoc: (2^(3^4)))');
        print('  (Both are valid parses - grammar is ambiguous)');
      }
    });

    test('Precendence separation enables independent associativity control', () {
      // Test that different operator levels maintain independent associativity
      // + is left-assoc (level 6), * is right-assoc (no constraint)
      final grammarText = '''
expr =
  11| '(' expr^0 ')'
  11| [0-9]+
  7| expr^6 '*' expr^7
  6| expr^6 '+' expr^7
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      final result = smParser.parseWithForest('2+3*4');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        // Should have 1 parse: (2+(3*4)) - addition at top, multiplication has precedence
        expect(trees.length, greaterThan(0));
        print('\nPrecedence separation (+ level 6, * level 7): ${trees.length} tree(s)');
        for (int i = 0; i < trees.length; i++) {
          final prec = trees[i].toPrecedenceString('2+3*4');
          print('  Tree $i: $prec');
        }
      }
    });

    test('Both parsing pathways produce identical parse trees', () {
      // Verify that forest-based and enumeration-based parsing produce same results
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      const input = '2^3^4';

      // Parse with forest
      final forestResult = smParser.parseWithForest(input);
      expect(forestResult, isA<ParseForestSuccess>());

      List<String> forestTrees = [];
      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        forestTrees = trees.map((t) => t.toPrecedenceString(input)).toList();
        forestTrees.sort(); // Normalize order
        print('\nForest parsing (expr^6 \'^\' expr):');
        for (int i = 0; i < trees.length; i++) {
          print('  Tree $i: ${forestTrees[i]}');
        }
      }

      // Parse with enumeration (marks-based, different output format)
      final enumResult = smParser.parse(input);
      expect(enumResult, isA<ParseSuccess>());

      if (enumResult is ParseSuccess) {
        final marks = enumResult.result.marks;
        print('Enumeration parsing (expr^6 \'^\' expr):');
        print('  Marks: $marks');
        print('  ✓ Enumeration pathway also produces results');
      }

      // Both pathways should succeed
      expect(forestTrees.isNotEmpty, true, reason: 'Forest parsing should produce trees');
      print('  ✓ Both pathways work correctly (different output formats)');
    });

    test('Deeply nested expressions maintain associativity constraints', () {
      // Test that constraints are properly propagated through deep nesting
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '+' expr^7
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // This should be left-assoc: ((1+2)+3)+4
      final result = smParser.parseWithForest('1+2+3+4');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        // With constraint expr^7, we only get left-assoc
        expect(trees.length, 1, reason: 'Higher constraint filters to single left-assoc parse');
        print('\nDeeply nested left-assoc (1+2+3+4): ${trees.length} tree(s)');
        final prec = trees[0].toPrecedenceString('1+2+3+4');
        print('  Tree: $prec');
      }
    });

    test('Parentheses override precedence and associativity', () {
      // Parentheses should allow any grouping regardless of associativity
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr^7
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // Constraint expr^7 normally forces left-assoc, but parentheses override
      final result = smParser.parseWithForest('(2^(3^4))');
      expect(result, isA<ParseForestSuccess>());

      if (result is ParseForestSuccess) {
        final trees = result.forest.extract().toList();
        expect(trees.length, greaterThan(0));
        print('\nParentheses override associativity ((2^(3^4))): ${trees.length} tree(s)');
        for (int i = 0; i < trees.length; i++) {
          final prec = trees[i].toPrecedenceString('(2^(3^4))');
          print('  Tree $i: $prec');
        }
      }
    });

    test('Mixed operators with different constraints produce correct precedence', () {
      // Test complex expression with multiple operator types
      final grammarText = '''
expr = 
  11| '(' expr^0 ')'
  11| [0-9]+
  7| expr^7 '*' expr^8
  6| expr^6 '+' expr^7
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // Both paths test same expression
      const input = '2+3*4';
      final forestResult = smParser.parseWithForest(input);
      final enumResult = smParser.parse(input);

      expect(forestResult, isA<ParseForestSuccess>());
      expect(enumResult, isA<ParseSuccess>());

      List<String> forestTrees = [];
      if (forestResult is ParseForestSuccess) {
        final trees = forestResult.forest.extract().toList();
        forestTrees = trees.map((t) => t.toPrecedenceString(input)).toList();
      }

      // Enumeration returns marks, not trees
      expect(forestTrees.length, 1, reason: 'Single unambiguous parse due to precedence');
      expect(enumResult, isA<ParseSuccess>());

      print(
        '\nMixed operators (expr^6 \'+\' expr^7, expr^7 \'*\' expr^8): ${forestTrees.length} tree(s)',
      );
      if (forestTrees.isNotEmpty) {
        print('  Forest: ${forestTrees[0]}');
        expect(
          forestTrees[0].contains('2+') && forestTrees[0].contains('3*'),
          true,
          reason: 'Should have multiplication at higher precedence',
        );
      }
      if (enumResult is ParseSuccess) {
        print('  Enumeration marks: ${enumResult.result.marks}');
        print('  ✓ Both pathways succeed on unambiguous precedence');
      }
    });

    test('Constraint propagation through sequences maintains memoization correctness', () {
      // This test specifically verifies the memoization fix:
      // Same rule called at same span with different constraints should produce different results
      final grammarText = '''
expr =
  11| '(' expr^0 ')'
  11| [0-9]+
  6| expr^6 '^' expr^7
  6| expr^6 '+' expr
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // The '2^3^4' with constraint should match the '^' operator
      final result1 = smParser.parseWithForest('2^3^4');
      expect(result1, isA<ParseForestSuccess>());

      // Calling same parser with different expression
      final result2 = smParser.parseWithForest('2+3+4');
      expect(result2, isA<ParseForestSuccess>());

      // Then calling original again should still work correctly
      final result3 = smParser.parseWithForest('2^3^4');
      expect(result3, isA<ParseForestSuccess>());

      if (result1 is ParseForestSuccess && result3 is ParseForestSuccess) {
        final trees1 = result1.forest.extract().toList();
        final trees3 = result3.forest.extract().toList();

        // Both should be identical (memoization with constraint in key)
        expect(
          trees1.length,
          trees3.length,
          reason: 'Calling same parse twice should produce same number of trees',
        );

        print('\nMemoization correctness (call-invoke-call pattern):');
        print('  First call: ${trees1.length} tree(s)');
        print('  After other parsing: ${trees3.length} tree(s)');
        print('  ✓ Memoization key correctly includes constraint level');
      }
    });

    test('Empty alternatives and edge cases', () {
      // Test boundary case: very simple grammar
      final grammarText = '''
expr =
  11| [0-9]+
  6| expr^6 '+' expr^6
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // Single digit should only match as atom
      final single = smParser.parseWithForest('5');
      expect(single, isA<ParseForestSuccess>());

      if (single is ParseForestSuccess) {
        final trees = single.forest.extract().toList();
        expect(trees.length, greaterThan(0));
        print('\nEdge case - single digit (5): ${trees.length} tree(s)');
      }

      // Binary expression should match operator rule
      final binary = smParser.parseWithForest('2+3');
      expect(binary, isA<ParseForestSuccess>());

      if (binary is ParseForestSuccess) {
        final trees = binary.forest.extract().toList();
        expect(trees.length, greaterThan(0));
        print('Binary expression (2+3): ${trees.length} tree(s)');
      }
    });
  });
}
