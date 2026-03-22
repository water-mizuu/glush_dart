import 'package:glush/glush.dart';

extension on Pattern {
  Pattern operator /(Pattern other) => Alt(this, Seq(not(), other));
}

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
          | $ONE s
        s = 's';
      """
          .toSMParser();

  final evaluator = Evaluator(
    ($) => {
      r'TWO': () => "(${$<String>()}${$<String>()})", //
      r'ONE': () => 's',
    },
  );

  for (int length = 1; length <= 5; ++length) {
    final input = 's' * length;
    final result = parser.parseAmbiguous(input);
    if (result is! ParseAmbiguousForestSuccess) {
      print("Failed to parse $input!");
      continue;
    }

    print(length);
    print("=" * 30);
    for (final markList in result.forest.allPaths()) {
      final rawMarks = markList.toStringList();
      final evaluated = evaluator.evaluate(rawMarks);
      print(evaluated);
    }
    print("");
  }
}

void orderedChoice() {
  var grammar = Grammar(() {
    late Rule s;
    s = Rule('', () => (Token.char('a') >> Token.char('b')) / Token.char('a'));

    return s;
  });
  var parser = SMParserMini(grammar);
  var result = parser.parseAmbiguous('ab');
  print(result);
  if (result case ParseAmbiguousForestSuccess result) {
    print(result.forest.allPaths().toList());
  }
}

void main() async {
  // mathSimple();
  // ambiguous();
  orderedChoice();
}
