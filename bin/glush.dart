import 'package:glush/glush.dart';

void main() async {
  final grammar = Grammar(() {
    late Rule expr, term, factor, __;

    expr = Rule(
      "expr",
      () =>
          Marker("add") >> expr() >> __() >> Token.char("+") >> __() >> expr() |
          Marker("sub") >> expr() >> __() >> Token.char("-") >> __() >> expr() |
          term(),
    );

    term = Rule(
      "term",
      () =>
          Marker("mul") >> term() >> __() >> Token.char("*") >> __() >> term() |
          Marker("div") >> term() >> __() >> Token.char("*") >> __() >> term() |
          factor(),
    );

    factor = Rule(
      "factor",
      () =>
          Marker("group") >> Token.char("(") >> __() >> expr() >> __() >> Token.char(")") |
          Marker("number") >> Token.charRange('0', '9'),
    );

    __ = Rule(
      "__",
      () => (Token.char(' ') | Token.char('\t') | Token.char('\n') | Token.char('\r')).star(),
    );

    return expr();
  });

  final parser = SMParser(grammar);
  print('Parser spawned successfully!');

  final result = parser.enumerateAllParses('1 + 2 + 3');
  for (final res in result) {
    print(res.toTreeString("1 + 2 + 3"));
  }
  print('Parser disposed.');
}
