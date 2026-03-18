import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('GrammarFileParser precedence', () {
    test('parses precedence levels correctly', () {
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

      // Check that we have one rule
      expect(grammarFile.rules.length, 1);
      final rule = grammarFile.rules[0];
      expect(rule.name, 'expr');

      // Check precedence levels are stored
      expect(rule.precedenceLevels.isNotEmpty, true);
      print('Parsed precedence levels: ${rule.precedenceLevels}');
    });

    test('GrammarFileCompiler applies precedence levels correctly to each alternative', () {
      final grammarText = '''
expr =
  11| '(' expr^0 ')'
  11| [0-9]+
  7| expr^7 '*' expr^8
  6| expr^6 '+' expr^6
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();

      // Compile to grammar
      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();

      // Create a parser
      final smParser = SMParser(grammar);

      // Test simple addition
      final result1 = smParser.parseWithForest('2+3');
      expect(result1, isA<ParseForestSuccess>());
      if (result1 is ParseForestSuccess) {
        final trees = result1.forest.extract().toList();
        expect(trees.length, 1, reason: 'Should have exactly 1 parse tree for unambiguous grammar');
        print('Test "2+3": ${trees[0].toPrecedenceString("2+3")}');
      }

      // Test precedence: 2+3*4 should parse 3*4 first (one correct parse tree)
      final result2 = smParser.parseWithForest('2+3*4');
      expect(result2, isA<ParseForestSuccess>());
      if (result2 is ParseForestSuccess) {
        final trees = result2.forest.extract().toList();
        expect(trees.length, 1, reason: 'Should have exactly 1 parse tree, not ambiguous');
        final precedenceStr = trees[0].toPrecedenceString('2+3*4');
        print('Test "2+3*4": $precedenceStr');
        // Should be ((2+)((3*)4)) meaning 2 + (3*4)
        expect(
          precedenceStr.contains('((2+)((3*)'),
          true,
          reason: 'Should show 2 + (3*4) grouping',
        );
      }

      // Test precedence: 2*3+4 should parse 2*3 first (one correct parse tree)
      final result3 = smParser.parseWithForest('2*3+4');
      expect(result3, isA<ParseForestSuccess>());
      if (result3 is ParseForestSuccess) {
        final trees = result3.forest.extract().toList();
        expect(trees.length, 1, reason: 'Should have exactly 1 parse tree, not ambiguous');
        final precedenceStr = trees[0].toPrecedenceString('2*3+4');
        print('Test "2*3+4": $precedenceStr');
        // Should be ((((2*)3)+)4) meaning (2*3) + 4
        expect(precedenceStr.contains('((((2*)'), true, reason: 'Should show (2*3) + 4 grouping');
      }

      // Test left-associativity: 2+3+4 should parse left-to-right
      final result4 = smParser.parseWithForest('2+3+4');
      expect(result4, isA<ParseForestSuccess>());
      if (result4 is ParseForestSuccess) {
        final trees = result4.forest.extract().toList();
        expect(trees.length, greaterThanOrEqualTo(1), reason: 'Should parse 2+3+4');
        print('Test "2+3+4": ${trees[0].toPrecedenceString("2+3+4")}');
      }
    });

    test('precedence constraints are properly applied to rule calls', () {
      final grammarText = '''
expr = 
  11| [0-9]+
  7| expr^7 '*' expr^8
  6| expr^6 '+' expr^6
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();

      // Check to ensure RuleRefPattern has the constraint
      final rule = grammarFile.rules[0];
      final pattern = rule.pattern;

      print('Pattern: $pattern');

      // Walk through the alternation to find RuleRefPatterns with constraints
      bool foundConstrainedCall = false;
      _walkPattern(pattern, (p) {
        if (p is RuleRefPattern && p.precedenceConstraint != null) {
          print('Found constrained rule call: ${p.ruleName}^${p.precedenceConstraint}');
          foundConstrainedCall = true;
        }
      });

      expect(foundConstrainedCall, true, reason: 'Should have constrained rule calls');
    });

    test('multiple operations with correct precedence and associativity', () {
      final grammarText = '''
expr =
  11| '(' expr^0 ')'
  11| [0-9]+
  7| expr^7 '*' expr^8
  7| expr^7 '/' expr^8
  6| expr^6 '+' expr^6
  6| expr^6 '-' expr^6
  ;
''';

      final parser = GrammarFileParser(grammarText);
      final grammarFile = parser.parse();

      final compiler = GrammarFileCompiler(grammarFile);
      final grammar = compiler.compile();
      final smParser = SMParser(grammar);

      // Debug: simple addition
      final result1 = smParser.parseWithForest('2+3');
      if (result1 is ParseForestSuccess) {
        final trees = result1.forest.extract().toList();
        print('Test "2+3": ${trees.length} parse tree(s)');
        print('  Tree: ${trees[0].toTreeString()}');
        print('  Precedence: ${trees[0].toPrecedenceString("2+3")}');
      }

      // Debug: chained addition (2+3+4)
      final result2 = smParser.parseWithForest('2+3+4');
      if (result2 is ParseForestSuccess) {
        final trees = result2.forest.extract().toList();
        print('\nTest "2+3+4": ${trees.length} parse tree(s)');
        if (trees.isNotEmpty) {
          final tree = trees[0];
          print('  Forest root: ${result2.forest.root}');
          print('  Forest nodes: ${result2.forest.countNodes()}');
          print('  Tree root: ${tree.node}');
          print('  Tree children count: ${tree.children.length}');
          print('  Tree: ${tree.toTreeString()}');
          print('  Precedence: ${tree.toPrecedenceString("2+3+4")}');
        }
      }

      // Complex expression: 2+3*4-1 should be (2+(3*4))-1
      final result3 = smParser.parseWithForest('2+3*4-1');
      expect(result3, isA<ParseForestSuccess>());
      if (result3 is ParseForestSuccess) {
        final trees = result3.forest.extract().toList();
        print('\nTest "2+3*4-1": ${trees.length} parse tree(s)');
        for (int i = 0; i < trees.length; i++) {
          print('  [$i] ${trees[i].toPrecedenceString("2+3*4-1")}');
        }
        // Should parse correctly with multiplication having higher precedence than addition/subtraction
        expect(trees.isNotEmpty, true);
      }
    });
  });
}

void _walkPattern(PatternExpr pattern, Function(PatternExpr) visit) {
  visit(pattern);

  switch (pattern) {
    case AlternationPattern p:
      for (final sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case SequencePattern p:
      for (final sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case ConjunctionPattern p:
      for (final sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case RepetitionPattern p:
      _walkPattern(p.pattern, visit);
    case GroupPattern p:
      _walkPattern(p.inner, visit);
    default:
      break;
  }
}
