import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Deeply recursive grammars', () {
    test('parses right recursive grammars correctly', () {
      final grammar = Grammar(() {
        late final Rule S;
        S = Rule(
          'S',
          () =>
              Pattern.char('s') | //
              Pattern.char('s') >> Pattern.char("+") >> S.call(),
        );

        return S.call();
      });

      final parser = SMParser(grammar);

      for (int count = 20; count <= 1000; count += 20) {
        Stopwatch watch = Stopwatch()..start();
        final input = "s+" * count + "s";

        expect(parser.parse(input), isNotNull);
        watch..stop();
      }
    });

    test('verifies conjunction logic at runtime', () {
      final grammar = Grammar(() {
        final digit = Token.charRange('0', '9');
        final even = Token(ExactToken(48)) |
            Token(ExactToken(50)) |
            Token(ExactToken(52)) |
            Token(ExactToken(54)) |
            Token(ExactToken(56));
        final even_digit = digit & even;
        return Rule('test', () => even_digit);
      });

      final parser = SMParser(grammar);
      expect(parser.recognize('0'), isTrue);
      expect(parser.recognize('2'), isTrue);
      expect(parser.recognize('1'), isFalse);
      expect(parser.recognize('a'), isFalse);
    });
  });
}
