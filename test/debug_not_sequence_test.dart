import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  test('NOT with sequence lookahead debug', () {
    final grammar = Grammar(() {
      final a = Token(ExactToken(97)); // 'a'
      final b = Token(ExactToken(98)); // 'b'
      final c = Token(ExactToken(99)); // 'c'
      final pattern = (b >> c).not() >> a >> b.maybe();
      print('Pattern: $pattern');
      return Rule('test', () => pattern);
    });

    final parser = SMParser(grammar);

    print('\n=== Grammar Test ===');
    final res1 = parser.recognize('a');
    print('recognize("a"): $res1 (expected: true)');

    final res2 = parser.recognize('ab');
    print('recognize("ab"): $res2 (expected: true - QUESTION)');

    final res3 = parser.recognize('abc');
    print('recognize("abc"): $res3 (expected: false)');

    // Additional tests to understand
    final res4 = parser.recognize('');
    print('recognize(""): $res4 (empty input?)');

    expect(res1, isTrue);
    expect(res2, isTrue); // Disable for now
    expect(res3, isFalse);
  });
}
