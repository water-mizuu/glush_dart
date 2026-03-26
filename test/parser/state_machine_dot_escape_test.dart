import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  test('State machine DOT export escapes whitespace in labels', () {
    final grammar = Grammar(() {
      return Rule(
        'S',
        () => Token.char(' ') >> Token.char('\n') >> Token.char('\t') >> Token.char('\r'),
      );
    });

    final parser = SMParser(grammar);
    final dot = parser.toDot();

    expect(dot, contains('token  '));
    expect(dot, contains(r'token \n'));
    expect(dot, contains(r'token \t'));
    expect(dot, contains(r'token \r'));
  });
}
