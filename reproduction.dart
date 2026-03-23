import 'package:glush/glush.dart';

/// Helper to check if a label exists in children
bool hasLabel(List<(String, ParseResult)> children, String label) {
  return children.any((element) => element.$1 == label);
}

/// Helper to get all results with a given label
List<ParseResult> getLabel(List<(String, ParseResult)> children, String label) {
  return [
    for (final (name, result) in children)
      if (name == label) result,
  ];
}

void main() {
  final parser =
      r'''
    S = ifStmt:("if" ws cond:("a") ws thenStmt:S (ws "else" ws elseStmt:S)?) | a:"a";
    ws = [ \n\r\t]*;
  '''
          .toSMParser();

  final input = 'if a if a a else a';
  final result = parser.parseAmbiguous(input, captureTokensAsMarks: true);

  if (result is ParseAmbiguousForestSuccess) {
    final forest = result.forest;
    final paths = forest.allPaths().toList();
    print('FOUND ${paths.length} PATHS');

    final evaluator = StructuredEvaluator();
    final trees = paths.map((p) => evaluator.evaluate(p)).toList();

    final uniqueTrees = trees.map((t) => t.toString()).toSet();
    print('uniqueTrees.length: ${uniqueTrees.length}');

    final hasOuterElse = trees.any((t) {
      final ifStmts = getLabel(t.children, 'ifStmt');
      return ifStmts.isNotEmpty && hasLabel(ifStmts.first.children, 'elseStmt');
    });
    final hasInnerElse = trees.any((t) {
      final outerIf = getLabel(t.children, 'ifStmt').firstOrNull;
      if (outerIf == null) return false;
      final thenS = getLabel(outerIf.children, 'thenStmt').firstOrNull;
      if (thenS == null) return false;
      return hasLabel(thenS.children, 'ifStmt') &&
          hasLabel(getLabel(thenS.children, 'ifStmt').first.children, 'elseStmt');
    });

    print('hasOuterElse: $hasOuterElse');
    print('hasInnerElse: $hasInnerElse');
  } else {
    print('RESULT: $result');
  }
}
