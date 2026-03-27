import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Grammar file if guards", () {
    test("parses and compiles guarded sequences", () {
      const grammarText = r'''
        start = if (position == 0 && ruleName == "start" && rule == start) "a";
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

      var parser = grammarText.toSMParser();
      expect(parser.recognize("a"), isFalse);
    });
  });
}
