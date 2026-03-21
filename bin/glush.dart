import 'package:glush/glush.dart';

void mathSimple() {
  final parser =
      r"""
        expr =
              $add expr _ '+' _ expr
            | $num [0-9]+

        _ = [ \t\n\r]*
      """
          .toSMParser();

  final input = '1 + 2 + 3';
  final ambiguousResult = parser.parseAmbiguous(input);
  final evaluator = Evaluator(
    ($) => {
      'add': () => "(${$<String>()} + ${$<String>()})", //
      'num': () => $<String>().trim(),
    },
  );
  if (ambiguousResult is ParseAmbiguousForestSuccess) {
    for (var result in ambiguousResult.forest.allPaths()) {
      print(evaluator.evaluate(result.toShortMarks()));
    }
  }
}

void ambiguous() {
  final parser =
      r"""
        S = $TWO S S
          | $ONE 's' 's'
          | $ONE 's'
      """
          .toSMParser();
  final input = 'sssss';
  final ambiguousResult = parser.parseWithForest(input);
  final evaluator = Evaluator(
    ($) => {
      r'TWO': () => "(${$<String>()}${$<String>()})", //
      r'ONE': () => $<String>(),
    },
  );
  if (ambiguousResult is ParseForestSuccess) {
    final forest = ambiguousResult.forest;

    print(forest.countDerivationsWithSCC());
    for (var result in ambiguousResult.forest.extract()) {
      print(evaluator.evaluate(parser.extractParseTreeMarks(result, input)));
    }
  }
}

void main() async {
  mathSimple();
  ambiguous();
}
