import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:test/test.dart";

void main() {
  group("Meta Grammar", () {
    late Grammar metaGrammar;
    late SMParser metaParser;

    // The meta grammar definition as a string

    setUp(() {
      // Compile the meta grammar
      metaGrammar = GrammarFileCompiler(
        GrammarFileParser(metaGrammarString).parse(),
      ).compile(startRuleName: "full");

      metaParser = SMParser(metaGrammar);
    });

    test("parses a simple single-rule grammar", () {
      const input = "rule = 'a'";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses a grammar with multiple rules", () {
      const input = """
        first = 'hello'
        second = 'world'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses rules with comments", () {
      const input = """
        # This is a comment
        rule = 'test'  # inline comment
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses choice expressions", () {
      const input = "rule = 'a' | 'b' | 'c'";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses sequence expressions", () {
      const input = "rule = 'a' 'b' 'c'";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses repetition operators", () {
      const input = """
        star = 'a'*
        plus = 'b'+
        question = 'c'?
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses greedy repetition operators", () {
      const input = """
        starBang = 'a'*!
        plusBang = 'b'+!
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses lookahead and negation", () {
      const input = """
        and = &'a' 'b'
        not = !'c' 'd'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses marked elements", () {
      const input = r"""
        rule = $mark 'test'
        another = $foo $bar 'baz'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses labeled elements", () {
      const input = """
        rule = name:'test'
        complex = first:a second:b third:c
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses character ranges", () {
      const input = """
        digits = [0-9]
        letter = [a-zA-Z]
        anything = [^a-z]
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses grouped expressions", () {
      const input = """
        rule = ('a' | 'b') 'c'
        complex = (first 'and' second) | (third 'or' fourth)
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses the dot wildcard", () {
      const input = "rule = .";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses rules with optional trailing semicolon", () {
      const input = """
        rule1 = 'a';
        rule2 = 'b'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses complex grammar with mixed operators", () {
      const input = r"""
        expr = $add expr '+' expr
             | $mul expr '*' expr
             | $num [0-9]+
        _ = [ \t\n\r]*
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("handles whitespace and newlines consistently", () {
      const input1 = "rule = 'a' 'b'";
      const input2 = """
        rule = 'a'
               'b'
      """;
      const input3 = "rule = 'a'    'b'";

      var result1 = metaParser.parse("$input1\n");
      var result2 = metaParser.parse("${input2.trim()}\n");
      var result3 = metaParser.parse("$input3\n");

      expect(result1, isA<ParseSuccess>());
      expect(result2, isA<ParseSuccess>());
      expect(result3, isA<ParseSuccess>());
    });

    test("self-parses: meta grammar can parse itself", () {
      // Note: The grammar must end with a newline for proper EOF handling
      // We validate parsing succeeds by checking the result type
      var result = metaParser.parseAmbiguous(metaGrammarString);

      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("self-parses: result contains valid parse structure", () {
      var parseResult = metaParser.parse(metaGrammarString);

      expect(parseResult, isA<ParseSuccess>());

      if (parseResult is ParseSuccess) {
        // Verify parse result has marks that can be evaluated
        expect(parseResult.rawMarks, isNotNull);
      }
    });

    test("rejects invalid grammar - missing equals sign", () {
      const input = "rule 'test'";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseError>());
    });

    test("rejects invalid grammar - unterminated string literal", () {
      const input = "rule = 'test";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseError>());
    });

    test("rejects invalid grammar - empty input", () {
      const input = "";
      var result = metaParser.parse(input);
      expect(result, isA<ParseError>());
    });

    test("parses complex precedence and associativity patterns", () {
      const input = """
        expr = left:expr '+' right:expr
             | left:expr '*' right:expr
             | value:[0-9]+
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("maintains stability across multiple parse cycles", () {
      var testInputs = ["simple = 'x'", "a = 'x' | 'y'", r"complex = [a-z]+ !'end' $mark"];

      for (int i = 0; i < 5; i++) {
        for (var input in testInputs) {
          var result = metaParser.parse("$input\n");
          expect(result, isA<ParseSuccess>(), reason: "Failed on iteration $i with input: $input");
        }
      }
    });

    test("handles deeply nested expressions", () {
      const input = "rule = ((((('a') | 'b') 'c') | 'd') | (('e' | 'f')))";
      var result = metaParser.parse("$input\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses identifiers with underscores and dollar signs", () {
      const input = r"""
        rule_name = 'test'
        $special = 'value'
        _private = 'data'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("parses both single and double quoted literals", () {
      const input = """
        single = 'single quoted'
        double = "double quoted"
        mixed = 'single' "double"
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("handles consecutive marks and labels", () {
      const input = r"""
        rule = $first $second first:'a' second:'b'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });

    test("correctly parses the isContinuation rule", () {
      const input = """
        cont = &isContinuation 'test'
        basic = 'a'
      """;
      var result = metaParser.parse("${input.trim()}\n");
      expect(result, isA<ParseSuccess>());
    });
  });
}
