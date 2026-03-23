import 'package:glush/glush.dart';

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

    final hasOuterElse = trees.any(
      (t) => t.children['ifStmt']?.first.children.containsKey('elseStmt') ?? false,
    );
    final hasInnerElse = trees.any((t) {
      final outerIf = t.children['ifStmt']?.first;
      if (outerIf == null) return false;
      final thenS = outerIf.children['thenStmt']?.first;
      if (thenS == null) return false;
      return thenS.children.containsKey('ifStmt') &&
          thenS.children['ifStmt']!.first.children.containsKey('elseStmt');
    });

    print('hasOuterElse: $hasOuterElse');
    print('hasInnerElse: $hasInnerElse');
  } else {
    print('RESULT: $result');
  }
}
