import 'dart:io';

import 'package:glush/glush.dart';
import '../expr_parser.dart' as parser;

void main() {
  const grammarText = r'''
    # Hello world!

    expr = $add expr '+' term | $sub expr '-' term | term;
    term = $mul term '*' factor | $div term '/' factor | factor;
    factor = $group '(' expr ')'
           | $number [0-9]+;
  ''';

  final markEvaluator = Evaluator<num>((consume) {
    return {
      "add": () => consume<num>() + consume<num>(),
      "sub": () => consume<num>() - consume<num>(),
      "mul": () => consume<num>() * consume<num>(),
      "div": () => consume<num>() / consume<num>(),
      "group": () => consume<num>(),
      "number": () => num.parse(consume<String>()),
    };
  });

  // Generate a standalone parser file
  final standaloneCode = generateStandaloneGrammarDartFile(grammarText);

  // Write it to a file
  File('expr_parser.dart').writeAsStringSync(standaloneCode);

  final result = parser.parseGrammarMarks('1+2*(3+4)');
  if (result case parser.ParseSuccess(:final result)) {
    var (evaluationResult, _) = markEvaluator.evaluate(result.marks);

    print("The answer is $evaluationResult");
  } else if (result case parser.ParseError result) {
    print(result);
  }
}
