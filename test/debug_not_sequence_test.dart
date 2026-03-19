import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  test('NOT with sequence lookahead debug', () {
    final grammar = Grammar(() {
      final a = Token(ExactToken(97)); // 'a'
      final b = Token(ExactToken(98)); // 'b'
      final c = Token(ExactToken(99)); // 'c'
      final pattern = (b >> c).not() >> a >> b.maybe();
      return Rule('test', () => pattern);
    });

    final parser = SMParser(grammar);

    final res1 = parser.recognize('a');
    final res2 = parser.recognize('ab');
    final res3 = parser.recognize('abc');
    final res4 = parser.recognize('');

    expect(res1, isTrue);
    expect(res2, isTrue);
    expect(res3, isFalse);
    expect(res4, isFalse);
  });
}
