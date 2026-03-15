import 'dart:io';

import 'package:glush/glush.dart';
import '../expr_parser.dart' as parser;

void main() {
  const grammarText = '''
    # Hello world!

    expr = expr ('+' | '-') term | term;
    term = term ('*' | '/') factor | factor;
    factor = '(' expr ')'
           | [0-9]+;
  ''';

  // Generate a standalone parser file
  final standaloneCode = generateStandaloneGrammarDartFile(grammarText);

  // Write it to a file
  File('expr_parser.dart').writeAsStringSync(standaloneCode);

  final results = parser.parseGrammar('1+2*3+4');
  for (final result in results) {
    print(result.children.map((v) => v.runtimeType).toList());
  }
}
