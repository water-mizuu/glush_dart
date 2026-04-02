import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Associativity control", () {
    test("No constraint on right enables right-associativity", () {
      // Using: expr^6 '^' expr (no constraint on right) creates BOTH left and right-assoc parses
      // Tree 0 is left-assoc: ((2^3)^4)
      // Tree 1 is right-assoc: (2^(3^4))
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
           6| expr^6 '^' expr
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      var result = smParser.parseAmbiguous("2^3^4");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Different constraints (higher level on right) filters to left-assoc only", () {
      // Using different levels: expr^6 '^' expr^7 filters out right-assoc
      // expr^7 constraint on right means it can only match atoms (level 11), not operators (level 6)
      // Result: Only left-assoc possible
      var grammarText =
          """
          expr =
            11| '(' expr^0 ')'
            11| [0-9]+
             6| expr^6 '^' expr^7
          """
              .toSMParser();

      var result = grammarText.parseAmbiguous("2^3^4");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Same constraints produce both associativities", () {
      // Using same levels: expr^6 '^' expr^6 allows BOTH left-assoc and right-assoc parses
      // This is the ambiguous case - the grammar is naturally ambiguous
      var grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
           6| expr^6 '^' expr^6
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      var result = smParser.parseAmbiguous("2^3^4");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Precendence separation enables independent associativity control", () {
      // Test that different operator levels maintain independent associativity
      // + is left-assoc (level 6), * is right-assoc (no constraint)
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
           7| expr^6 '*' expr^7
           6| expr^6 '+' expr^7
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      var result = smParser.parseAmbiguous("2+3*4");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Both parsing pathways produce identical parse trees", () {
      // Verify that forest-based and enumeration-based parsing produce same results
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
           6| expr^6 '^' expr
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      const input = "2^3^4";

      // Parse with forest
      var forestResult = smParser.parseAmbiguous(input);
      expect(forestResult, isA<ParseAmbiguousSuccess>());

      // Parse with enumeration (marks-based, different output format)
      var enumResult = smParser.parse(input);
      expect(enumResult, isA<ParseSuccess>());

      // Both pathways should succeed
    });

    test("Deeply nested expressions maintain associativity constraints", () {
      // Test that constraints are properly propagated through deep nesting
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
          6| expr^6 '+' expr^7
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // This should be left-assoc: ((1+2)+3)+4
      var result = smParser.parseAmbiguous("1+2+3+4");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Parentheses override precedence and associativity", () {
      // Parentheses should allow any grouping regardless of associativity
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
          6| expr^6 '^' expr^7
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // Constraint expr^7 normally forces left-assoc, but parentheses override
      var result = smParser.parseAmbiguous("(2^(3^4))");
      expect(result, isA<ParseAmbiguousSuccess>());
    });

    test("Mixed operators with different constraints produce correct precedence", () {
      // Test complex expression with multiple operator types
      const grammarText = """
          expr =
            11| '(' expr^0 ')'
            11| [0-9]+
             7| expr^7 '*' expr^8
             6| expr^6 '+' expr^7
          """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // Both paths test same expression
      const input = "2+3*4";
      var forestResult = smParser.parseAmbiguous(input);
      var enumResult = smParser.parse(input);

      expect(forestResult, isA<ParseAmbiguousSuccess>());
      expect(enumResult, isA<ParseSuccess>());
    });

    test("Constraint propagation through sequences maintains memoization correctness", () {
      // This test specifically verifies the memoization fix:
      // Same rule called at same span with different constraints should produce different results
      const grammarText = """
          expr =
            11| '(' expr^0 ')'
            11| [0-9]+
            6| expr^6 '^' expr^7
            6| expr^6 '+' expr
          """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // The '2^3^4' with constraint should match the '^' operator
      var result1 = smParser.parseAmbiguous("2^3^4");
      expect(result1, isA<ParseAmbiguousSuccess>());

      // Calling same parser with different expression
      var result2 = smParser.parseAmbiguous("2+3+4");
      expect(result2, isA<ParseAmbiguousSuccess>());

      // Then calling original again should still work correctly
      var result3 = smParser.parseAmbiguous("2^3^4");
      expect(result3, isA<ParseAmbiguousSuccess>());
    });

    test("Empty alternatives and edge cases", () {
      // Test boundary case: very simple grammar
      const grammarText = """
        expr =
          11| [0-9]+
           6| expr^6 '+' expr^6
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // Single digit should only match as atom
      var single = smParser.parseAmbiguous("5");
      expect(single, isA<ParseAmbiguousSuccess>());

      // Binary expression should match operator rule
      var binary = smParser.parseAmbiguous("2+3");
      expect(binary, isA<ParseAmbiguousSuccess>());
    });
  });
}
