import 'package:glush/glush.dart';

void main() async {
  final grammar = r"""
    expr = $add expr _ '+' _ expr
         | $sub expr _ '-' _ expr
         | term

    term = $mul term _ '*' _ term
         | $div term _ '/' _ term
         | factor

    factor = $group '(' _ expr _ ')'
           | $number number

    number = number [0-9]
           | [1-9]

    # _ = _ [ \t\n\r] | [ \t\n\r]
    _ = [ \t\n\r]*
    """;
  final parser = SMParser(GrammarFileCompiler(GrammarFileParser(grammar).parse()).compile());
  final result = parser.parseWithForest('1 + 2 + 345');
  if (result is ParseForestSuccess) {
    for (final r in result.forest.extract()) {
      print(r);
    }
  }
}
