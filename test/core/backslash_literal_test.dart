import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  group('Backslash Literals', () {
    test('matches whitespace literals', () {
      final grammarText = r'''
        msg = 'hello' ws 'world'
        ws = \s*
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('helloworld'), isTrue);
      expect(parser.recognize('hello world'), isTrue);
      expect(parser.recognize('hello\nworld'), isTrue);
      expect(parser.recognize('hello\tworld'), isTrue);
      expect(parser.recognize('hello \r\n world'), isTrue);
    });

    test('matches non-whitespace literal', () {
      final grammarText = r'''
        nonws = \S+
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('abc'), isTrue);
      expect(parser.recognize('a b'), isFalse);
      expect(parser.recognize(' '), isFalse);
      expect(parser.recognize('\n'), isFalse);
    });

    test('matches digit literals', () {
      final grammarText = r'''
        num = \d+
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('123'), isTrue);
      expect(parser.recognize('0'), isTrue);
      expect(parser.recognize('a'), isFalse);
      expect(parser.recognize(''), isFalse);
    });

    test('matches non-digit literals', () {
      final grammarText = r'''
        nondigit = \D+
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('abc'), isTrue);
      expect(parser.recognize('123'), isFalse);
      expect(parser.recognize('a1b'), isFalse);
    });

    test('matches word literals', () {
      final grammarText = r'''
        word = \w+
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('abc'), isTrue);
      expect(parser.recognize('ABC'), isTrue);
      expect(parser.recognize('123'), isTrue);
      expect(parser.recognize('foo_bar'), isTrue);
      expect(parser.recognize('foo-bar'), isFalse);
      expect(parser.recognize(' '), isFalse);
    });

    test('matches non-word literals', () {
      final grammarText = r'''
        nonword = \W+
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('!@#'), isTrue);
      expect(parser.recognize(' '), isTrue);
      expect(parser.recognize('abc'), isFalse);
      expect(parser.recognize('123'), isFalse);
    });

    test('matches newline and carriage return', () {
      final grammarText = r'''
        line = 'a' \n 'b' \r 'c' \t 'd'
      ''';
      final parser = grammarText.toSMParser();

      expect(parser.recognize('a\nb\rc\td'), isTrue);
      expect(parser.recognize('a b c d'), isFalse);
    });
  });
}
