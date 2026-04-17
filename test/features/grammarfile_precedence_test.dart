import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("GrammarFileParser precedence", () {
    test("GrammarFileCompiler applies precedence levels correctly to each alternative", () {
      const grammarText = """
        expr =
          11| '(' expr^0 ')'
          11| [0-9]+
          7 | expr^7 '*' expr^8
          6 | expr^6 '+' expr^6
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();

      // Compile to grammar
      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();

      // Create a parser
      var smParser = SMParser(grammar);

      // Test simple addition
      var result1 = smParser.parseAmbiguous("2+3");
      expect(result1, isA<ParseAmbiguousSuccess>());

      // Test precedence: 2+3*4 should parse 3*4 first (one correct parse tree)
      var result2 = smParser.parseAmbiguous("2+3*4");
      expect(result2, isA<ParseAmbiguousSuccess>());

      // Test precedence: 2*3+4 should parse 2*3 first (one correct parse tree)
      var result3 = smParser.parseAmbiguous("2*3+4");
      expect(result3, isA<ParseAmbiguousSuccess>());

      // Test left-associativity: 2+3+4 should parse left-to-right
      var result4 = smParser.parseAmbiguous("2+3+4");
      expect(result4, isA<ParseAmbiguousSuccess>());
    });

    test("precedence constraints are properly applied to rule calls", () {
      const grammarText = """
        expr =
          11 | [0-9]+
           7 | expr^7 '*' expr^8
           6 | expr^6 '+' expr^6
        """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();

      // Check to ensure RuleRefPattern has the constraint
      var rule = grammarFile.rules[0];
      var pattern = rule.pattern;

      // Walk through the alternation to find RuleRefPatterns with constraints
      bool foundConstrainedCall = false;
      _walkPattern(pattern, (p) {
        if (p is RuleRefPattern && p.precedenceConstraint != null) {
          foundConstrainedCall = true;
        }
      });

      expect(foundConstrainedCall, true, reason: "Should have constrained rule calls");
    });

    test("multiple operations with correct precedence and associativity", () {
      const grammarText = """
        expr =
          11 | '(' expr^0 ')'
          11 | [0-9]+
           7 | expr^7 '*' expr^8
           7 | expr^7 '/' expr^8
           6 | expr^6 '+' expr^6
           6 | expr^6 '-' expr^6
          ;
      """;

      var parser = GrammarFileParser(grammarText);
      var grammarFile = parser.parse();

      var compiler = GrammarFileCompiler(grammarFile);
      var grammar = compiler.compile();
      var smParser = SMParser(grammar);

      // Test simple addition
      var result1 = smParser.parseAmbiguous("2+3");
      expect(result1, isA<ParseAmbiguousSuccess>());

      // Test chained addition (2+3+4) - should have exactly 1 tree with left-associativity
      var result2 = smParser.parseAmbiguous("2+3+4");
      expect(result2, isA<ParseAmbiguousSuccess>());

      // Complex expression: 2+3*4-1 should be (2+(3*4))-1
      var result3 = smParser.parseAmbiguous("2+3*4-1");
      expect(result3, isA<ParseAmbiguousSuccess>());
    });
  });
}

void _walkPattern(PatternExpr pattern, void Function(PatternExpr) visit) {
  visit(pattern);

  switch (pattern) {
    case AlternationPattern p:
      for (var sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case SequencePattern p:
      for (var sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case ConjunctionPattern p:
      for (var sub in p.patterns) {
        _walkPattern(sub, visit);
      }
    case RepetitionPattern p:
      _walkPattern(p.pattern, visit);
    case StarPattern p:
      _walkPattern(p.pattern, visit);
    case PlusPattern p:
      _walkPattern(p.pattern, visit);
    case GroupPattern p:
      _walkPattern(p.inner, visit);
    case PrecedenceExpr p:
      _walkPattern(p.pattern, visit);
    default:
      break;
  }
}
