import 'package:test/test.dart';
import 'package:glush/glush.dart';

void main() {
  group('Grammar File Conjunction (&)', () {
    test('parses and generates conjunction', () {
      final grammarText = '''
        digit = [0-9];
        even = [02468];
        even_digit = digit&even;
      ''';

      final dartCode = generateGrammarDartFile(grammarText);
      expect(dartCode, contains('Call(digit) & Call(even)'));
    });

    test('verifies conjunction logic at runtime', () {
      final grammar = Grammar(() {
        final digit = Token.charRange('0', '9');
        final even =
            Token(ExactToken(48)) |
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
