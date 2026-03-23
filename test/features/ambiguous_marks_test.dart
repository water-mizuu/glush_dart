import 'package:test/test.dart';
import 'package:glush/glush.dart';

/// Helper to check if a label exists in children
bool hasLabel(List<(String label, ParseNode node)> children, String label) {
  return children.any((element) => element.$1 == label);
}

/// Helper to get all results with a given label
List<ParseNode> getLabel(List<(String label, ParseNode node)> children, String label) {
  return [
    for (final (name, node) in children)
      if (name == label) node,
  ];
}

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

      expect(trees.any((t) => hasLabel(t.children, 'a')), isTrue);
      expect(trees.any((t) => hasLabel(t.children, 'b')), isTrue);
      expect(trees.any((t) => getLabel(t.children, 'a').firstOrNull?.span == 'z'), isTrue);
      expect(trees.any((t) => getLabel(t.children, 'b').firstOrNull?.span == 'z'), isTrue);
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

      final hasA = trees.any((t) => hasLabel(t.children, 'a'));
      final hasB = trees.any((t) => hasLabel(t.children, 'b'));

      expect(hasA, isTrue);
      expect(hasB, isTrue);
    });

    test('3. Dangling Else with Labels', () {
      final parser =
          r'''
        S = $ifStmt "if" _ thenStmt:S (_ "else" _ elseStmt:S)? | a:"a";
        _ = [ \t\n\r]*;
      '''
              .toSMParser();

      final input = 'if if a else a';
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
      final hasOuterElse = trees.any((t) {
        final ifStmts = getLabel(t.children, 'ifStmt');
        return ifStmts.isNotEmpty &&
            ifStmts.first is ParseResult &&
            hasLabel((ifStmts.first as ParseResult).children, 'elseStmt');
      });

      // The other should have it in the nested 'thenStmt' -> 'ifStmt'
      final hasInnerElse = trees.any((t) {
        final outerIf = getLabel(t.children, 'ifStmt').firstOrNull as ParseResult?;
        if (outerIf == null) return false;
        final thenS = getLabel(outerIf.children, 'thenStmt').firstOrNull as ParseResult?;
        if (thenS == null) return false;
        final innerIfStmts = getLabel(thenS.children, 'ifStmt');
        return innerIfStmts.isNotEmpty &&
            innerIfStmts.first is ParseResult &&
            hasLabel((innerIfStmts.first as ParseResult).children, 'elseStmt');
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

      final treeAA = paths.map((p) => evaluator.evaluate(p)).firstWhere((tree) {
        return hasLabel(tree.children, 'a') && getLabel(tree.children, 'a').length == 2;
      });
      expect(getLabel(treeAA.children, 'a').length, equals(2));
    });
  });
}
