import 'dart:io';

import 'package:glush/glush.dart';
import '../expr_parser.dart' as parser;

(num, List<String>) evaluate(List<String> values) {
  switch (values) {
    case ['add', ...var rest]:
      var (left, rest0) = evaluate(rest);
      var (right, rest1) = evaluate(rest0);

      return (left + right, rest1);
    case ['sub', ...var rest]:
      var (left, rest0) = evaluate(rest);
      var (right, rest1) = evaluate(rest0);

      return (left - right, rest1);
    case ['mul', ...var rest]:
      var (left, rest0) = evaluate(rest);
      var (right, rest1) = evaluate(rest0);

      return (left * right, rest1);
    case ['div', ...var rest]:
      var (left, rest0) = evaluate(rest);
      var (right, rest1) = evaluate(rest0);

      return (left / right, rest1);
    case ['group', ...var rest]:
      var (value, rest0) = evaluate(rest);

      return (value, rest0);
    case ['number', String numRaw, ...var rest]:
      return (num.parse(numRaw), rest);
    case _:
      throw UnsupportedError(values[0]);
  }
}

void main() {
  const grammarText = '''
    # Hello world!

    expr = \$add expr '+' term | \$sub expr '-' term | term;
    term = \$mul term '*' factor | \$div term '/' factor | factor;
    factor = \$group '(' expr ')'
           | \$number [0-9]+;
  ''';

  // Generate a standalone parser file
  final standaloneCode = generateStandaloneGrammarDartFile(grammarText);

  // // Write it to a file
  File('expr_parser.dart').writeAsStringSync(standaloneCode);

  final result = parser.parseGrammarMarks('1+2*(3+4)');
  if (result case parser.ParseSuccess(:final result)) {
    var (evaluationResult, _) = evaluate(result.marks);

    print("The answer is $evaluationResult");
  } else if (result case parser.ParseError result) {
    print(result);
  }
}
