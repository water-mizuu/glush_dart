import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Grammar file if guards", () {
    test("parses and compiles guarded sequences", () {
      const grammarText = r'''
        start = if (position == 0 && ruleName == "start") "a";
      ''';

      var grammarFile = GrammarFileParser(grammarText).parse();
      expect(grammarFile.rules, hasLength(1));
      expect(grammarFile.rules.first.pattern, isA<IfPattern>());

      var parser = SMParser(GrammarFileCompiler(grammarFile).compile());
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("rejects sequences when the guard is false", () {
      const grammarText = r'''
        start = if (position > 0) "a";
      ''';

      var parser = grammarText.toSMParserMini();
      expect(parser.recognize("a"), isFalse);
    });

    test("captures expose span length in guards", () {
      const grammarText = r"""
        start = t:repeat(3) check(capture.length, capture)
        repeat(n) = if (n > 1) repeat(n - 1) 's'
                 | if (n == 1) 's'
        check(length, start) = if (length == 3 && start.startPosition == 0) ''
      """;

      var parser = grammarText.toSMParser();

      for (var rule in parser.stateMachine.grammar.rules) {
        print((rule.name, rule.body()));
      }

      expect(parser.recognize("sss"), isTrue);
      expect(parser.parse("sss"), isA<ParseSuccess>());
    });

    test("recursive capture references can be passed into later call arguments", () {
      const grammarText = r"""
        start = capture:times(3, 's') check(capture, 3) '!'

        times(n, char) = _times(n, char)
        _times(n, char) = if (n > 1) cdr:_times(n - 1, char) car:char
                       | if (n == 1) char
                       | if (n <= 0) ''

        check(value, n) = if (value.length == n) ''
      """;

      var parser = grammarText.toSMParser();
      expect(parser.recognize("sss!"), isTrue);
      expect(parser.parse("sss!"), isA<ParseSuccess>());
      expect(parser.recognize("ssss!"), isFalse);
      expect(parser.parse("ssss!"), isA<ParseError>());
      expect(parser.recognize("ss!"), isFalse);
      expect(parser.parse("ss!"), isA<ParseError>());
    });

    test("label captures are visible to later calls in the same body", () {
      const grammarText = r'''
        start = capture:"abc" check(capture.length) '!'
        check(length) = if (length == 3) ''
      ''';

      var parser = grammarText.toSMParser();
      expect(parser.recognize("abc!"), isTrue);
      expect(parser.parse("abc!"), isA<ParseSuccess>());
    });
  });
}
