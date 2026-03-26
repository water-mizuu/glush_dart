import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Grammar File Conjunction (&)", () {
    // test('parses and generates conjunction', () {
    //   final grammarText = '''
    //     digit = [0-9];
    //     even = [02468];
    //     even_digit = digit&even;
    //   ''';

    //   final dartCode = generateGrammarDartFile(grammarText);
    //   expect(dartCode, contains('digit() & even()'));
    // });

    test("verifies conjunction logic at runtime", () {
      var grammar = Grammar(() {
        var digit = Token.charRange("0", "9");
        var even =
            Token(const ExactToken(48)) |
            Token(const ExactToken(50)) |
            Token(const ExactToken(52)) |
            Token(const ExactToken(54)) |
            Token(const ExactToken(56));
        var evenDigit = digit & even;
        return Rule("test", () => evenDigit);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("0"), isTrue);
      expect(parser.recognize("2"), isTrue);
      expect(parser.recognize("1"), isFalse);
      expect(parser.recognize("a"), isFalse);
    });
  });
}
