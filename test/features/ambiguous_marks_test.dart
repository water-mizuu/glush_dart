import "package:glush/glush.dart";
import "package:test/test.dart";

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
  group("Ambiguous Marks (Label) Tests", () {
    test("1. Simple Alternative Labels", () {
      var parser = "S = a:([a-z]) | b:([a-z])".toSMParser();
      var result = parser.parseAmbiguous("z", captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousSuccess>());
      var forest = (result as ParseAmbiguousSuccess).forest;

      var paths = forest.allPaths().toList();
      expect(paths.length, equals(2));

      var evaluator = const StructuredEvaluator();
      var trees = paths.map((p) => evaluator.evaluate(p)).toList();

      expect(trees.any((t) => hasLabel(t.children, "a")), isTrue);
      expect(trees.any((t) => hasLabel(t.children, "b")), isTrue);
      expect(trees.any((t) => getLabel(t.children, "a").firstOrNull?.span == "z"), isTrue);
      expect(trees.any((t) => getLabel(t.children, "b").firstOrNull?.span == "z"), isTrue);
    });

    test("2. Overlapping Labels", () {
      // "ab" can be parsed as (label 'a' covers "ab") OR ("a" then label 'b' covers "b")
      var parser = 'S = a:("a" "b") | "a" b:("b")'.toSMParser();
      var result = parser.parseAmbiguous("ab", captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousSuccess>());
      var forest = (result as ParseAmbiguousSuccess).forest;

      var paths = forest.allPaths().toList();
      expect(paths.length, equals(2));

      var evaluator = const StructuredEvaluator();

      // We don't guarantee the order of paths in BranchedList, so we check both
      var trees = paths.map((p) => evaluator.evaluate(p)).toList();

      var hasA = trees.any((t) => hasLabel(t.children, "a"));
      var hasB = trees.any((t) => hasLabel(t.children, "b"));

      expect(hasA, isTrue);
      expect(hasB, isTrue);
    });

    test("3. Dangling Else with Labels", () {
      var parser =
          r'''
        S = $ifStmt "if" _ thenStmt:S (_ "else" _ elseStmt:S)? | a:"a";
        _ = [ \t\n\r]*;
      '''
              .toSMParser();

      const input = "if if a else a";
      var result = parser.parseAmbiguous(input, captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousSuccess>());
      var forest = (result as ParseAmbiguousSuccess).forest;
      var paths = forest.allPaths().toList();

      var evaluator = const StructuredEvaluator();
      var trees = paths.map((p) => evaluator.evaluate(p)).toList();

      // We use a Set of stringified trees to count unique interpretations
      var uniqueTrees = trees.map((t) => t.toString()).toSet();

      // Expected 2 unique interpretations: inner else vs outer else
      expect(uniqueTrees.length, equals(2));

      // One tree should have 'elseStmt' in the outer 'ifStmt'
      var hasOuterElse = trees.any((t) {
        var ifStmts = getLabel(t.children, "S.ifStmt");
        return ifStmts.isNotEmpty &&
            ifStmts.first is ParseResult &&
            hasLabel((ifStmts.first as ParseResult).children, "elseStmt");
      });

      // The other should have it in the nested 'thenStmt' -> 'ifStmt'
      var hasInnerElse = trees.any((t) {
        var outerIf = getLabel(t.children, "S.ifStmt").firstOrNull as ParseResult?;
        if (outerIf == null) {
          return false;
        }
        var thenS = getLabel(outerIf.children, "thenStmt").firstOrNull as ParseResult?;
        if (thenS == null) {
          return false;
        }
        var innerIfStmts = getLabel(thenS.children, "S.ifStmt");
        return innerIfStmts.isNotEmpty &&
            innerIfStmts.first is ParseResult &&
            hasLabel((innerIfStmts.first as ParseResult).children, "elseStmt");
      });

      expect(hasOuterElse, isTrue);
      expect(hasInnerElse, isTrue);
    });

    test("4. Repetition Ambiguity", () {
      // S = (a:([a-z]) | b:([a-z]))+
      // For "a", should have 2 paths. For "aa", should have 4 paths.
      var parser = "S = (a:([a-z]) | b:([a-z]))+".toSMParser();

      var result1 = parser.parseAmbiguous("a", captureTokensAsMarks: true);
      expect((result1 as ParseAmbiguousSuccess).forest.allPaths().length, equals(2));

      var result2 = parser.parseAmbiguous("aa", captureTokensAsMarks: true);
      expect((result2 as ParseAmbiguousSuccess).forest.allPaths().length, equals(4));

      var forest2 = result2.forest;
      var paths = forest2.allPaths().toList();
      var evaluator = const StructuredEvaluator();

      var treeAA = paths.map((p) => evaluator.evaluate(p)).firstWhere((tree) {
        return hasLabel(tree.children, "a") && getLabel(tree.children, "a").length == 2;
      });
      expect(getLabel(treeAA.children, "a").length, equals(2));
    });

    test("5. Data-driven choice stays ambiguous and preserves labels", () {
      const grammarText = r"""
        start = leftStart | rightStart
        leftStart = branch(choice: left)
        rightStart = branch(choice: right)

        branch(choice) = choice
        left = leftMark:'a'
        right = rightMark:'a'
      """;

      var parser = grammarText.toSMParser();
      var result = parser.parseAmbiguous("a", captureTokensAsMarks: true);

      expect(result, isA<ParseAmbiguousSuccess>());
      var forest = (result as ParseAmbiguousSuccess).forest;

      var paths = forest.allPaths().toList();
      expect(paths.length, equals(2));

      var evaluator = const StructuredEvaluator();
      var trees = paths.map((p) => evaluator.evaluate(p)).toList();

      expect(trees.any((t) => hasLabel(t.children, "leftMark")), isTrue);
      expect(trees.any((t) => hasLabel(t.children, "rightMark")), isTrue);
      expect(trees.every((t) => t.span == "a"), isTrue);
    });
  });
}
