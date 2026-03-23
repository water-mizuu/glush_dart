import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Ambiguous Marks (Label) Tests', () {
    test('1. Simple Alternative Labels', () {
      final parser = r'S = a:([a-z]) | b:([a-z])'.toSMParser();
      final result = parser.parseAmbiguous('z', captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousForestSuccess>());
      final forest = (result as ParseAmbiguousForestSuccess).forest;

      final paths = forest.allPaths().toList();
      expect(paths.length, equals(2));

      final evaluator = StructuredEvaluator();
      final trees = paths.map((p) => evaluator.evaluate(p)).toList();

      expect(trees.any((t) => t.children.containsKey('a')), isTrue);
      expect(trees.any((t) => t.children.containsKey('b')), isTrue);
      expect(trees.any((t) => t['a']?.first.span == 'z'), isTrue);
      expect(trees.any((t) => t['b']?.first.span == 'z'), isTrue);
    });

    test('2. Overlapping Labels', () {
      // "ab" can be parsed as (label 'a' covers "ab") OR ("a" then label 'b' covers "b")
      final parser = r'S = a:("a" "b") | "a" b:("b")'.toSMParser();
      final result = parser.parseAmbiguous('ab', captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousForestSuccess>());
      final forest = (result as ParseAmbiguousForestSuccess).forest;

      final paths = forest.allPaths().toList();
      expect(paths.length, equals(2));

      final evaluator = StructuredEvaluator();

      // We don't guarantee the order of paths in BranchedList, so we check both
      final trees = paths.map((p) => evaluator.evaluate(p)).toList();

      final hasA = trees.any((t) => t.children.containsKey('a'));
      final hasB = trees.any((t) => t.children.containsKey('b'));

      expect(hasA, isTrue);
      expect(hasB, isTrue);
    });

    test('3. Dangling Else with Labels', () {
      final parser =
          r'''
        S = ifStmt:("if" ws cond:("a") ws thenStmt:S (ws "else" ws elseStmt:S)?) | a:"a";
        ws = [ \t\n\r]*;
      '''
              .toSMParser();

      final input = 'if a if a a else a';
      final result = parser.parseAmbiguous(input, captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousForestSuccess>());
      final forest = (result as ParseAmbiguousForestSuccess).forest;
      final paths = forest.allPaths().toList();

      final evaluator = StructuredEvaluator();
      final trees = paths.map((p) => evaluator.evaluate(p)).toList();

      // We use a Set of stringified trees to count unique interpretations
      final uniqueTrees = trees.map((t) => t.toString()).toSet();

      // Expected 2 unique interpretations: inner else vs outer else
      expect(uniqueTrees.length, equals(2));

      // One tree should have 'elseStmt' in the outer 'ifStmt'
      final hasOuterElse = trees.any(
        (t) => t.children['ifStmt']!.first.children.containsKey('elseStmt'),
      );

      // The other should have it in the nested 'thenStmt' -> 'ifStmt'
      final hasInnerElse = trees.any((t) {
        final outerIf = t.children['ifStmt']?.first;
        if (outerIf == null) return false;
        final thenS = outerIf.children['thenStmt']?.first;
        if (thenS == null) return false;
        return thenS.children['ifStmt']!.first.children.containsKey('elseStmt');
      });

      expect(hasOuterElse, isTrue);
      expect(hasInnerElse, isTrue);
    });

    test('4. Repetition Ambiguity', () {
      // S = (a:([a-z]) | b:([a-z]))+
      // For "a", should have 2 paths. For "aa", should have 4 paths.
      final parser = r'S = (a:([a-z]) | b:([a-z]))+'.toSMParser();

      final result1 = parser.parseAmbiguous('a', captureTokensAsMarks: true);
      expect((result1 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(2));

      final result2 = parser.parseAmbiguous('aa', captureTokensAsMarks: true);
      expect((result2 as ParseAmbiguousForestSuccess).forest.allPaths().length, equals(4));

      final forest2 = result2.forest;
      final paths = forest2.allPaths().toList();
      final evaluator = StructuredEvaluator();

      final treeAA = evaluator.evaluate(
        paths.firstWhere((p) {
          final tree = evaluator.evaluate(p);
          return tree.children.containsKey('a') && tree['a']!.length == 2;
        }),
      );
      expect(treeAA['a']!.length, equals(2));
    });
  });
}
