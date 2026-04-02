import "package:glush/glush.dart";

/// Example: Using the DSL (string-based) grammar format with operator precedence
///
/// This demonstrates how to define operator precedence using the grammar file format,
/// which provides a more natural syntax for specifying grammar rules with precedence levels.
void main() {
  print("╔════════════════════════════════════════════════════════════╗");
  print("║  DSL Grammar Example: Expression with Operator Precedence  ║");
  print("╚════════════════════════════════════════════════════════════╝");
  print("");

  // Grammar definition using the DSL string format
  // Precedence syntax:
  //   N| pattern    - Labels a pattern with precedence level N
  //   rule^N        - Calls a rule with minimum precedence constraint N
  //
  // In this example:
  //   - Atoms (numbers, parenthesized expressions) have level 11
  //   - Multiplication/Division (*,/) have level 7
  //   - Addition/Subtraction (+,-) have level 6
  //   - Lower numbers have lower precedence (bind less tightly)
  //
  // Constraint strategy for LEFT-ASSOCIATIVITY (standard for arithmetic):
  //   - Left operand: constrained to >= current precedence level
  //   - Right operand: constrained to STRICTLY HIGHER precedence level
  //   - This prevents "a+b+c" from becoming "a+(b+c)" (right-assoc)
  //   - Instead it becomes "(a+b)+c" (left-assoc) since right side needs level 7+

  const grammarText = """
# Expression grammar with operator precedence using DSL syntax

expr =
  11| '(' expr^0 ')'
  11| [0-9]+
  8 | expr^9 '^' expr^8
  7 | expr^7 '*' expr^8
  7 | expr^7 '/' expr^8
  6 | expr^6 '+' expr^7
  6 | expr^6 '-' expr^7
    ;
""";

  print("Grammar Definition (DSL format):");
  print("─" * 60);
  print(grammarText);
  print("─" * 60);
  print("");

  try {
    // Parse the grammar file
    var grammarParser = GrammarFileParser(grammarText);
    var grammarFile = grammarParser.parse();

    print("✓ Grammar parsed successfully!");
    print("");

    // Display parsed rules
    print("Parsed Rules:");
    for (var rule in grammarFile.rules) {
      print("  ${rule.name}: ${rule.pattern}");
      if (rule.precedenceLevels.isNotEmpty) {
        print("    Precedence levels assigned: ${rule.precedenceLevels.values.toSet()}");
      }
    }
    print("");

    // Compile to executable grammar using the GrammarFileCompiler
    var grammarCompiler = GrammarFileCompiler(grammarFile);
    var compiledGrammar = grammarCompiler.compile();

    print("✓ Grammar compiled to executable format");
    print("");

    // Create parser from compiled grammar
    var parser = SMParser(compiledGrammar);
    print("✓ Parser initialized with precedence constraints");
    print("");

    // Test cases showing how precedence affects parsing
    var testCases = [
      ("2+3", "simple addition"),
      ("2*3", "simple multiplication"),
      ("2+3*4", "addition and multiplication (3*4 should bind first)"),
      ("2*3+4", "multiplication and addition (2*3 should bind first)"),
      ("2+3+4", "chained addition (left-associative)"),
      ("2*3*4", "chained multiplication (left-associative)"),
      ("(2+3)*4", "parentheses override precedence"),
      ("2*(3+4)", "multiplication with parenthesized sum"),
      ("2+3*4+5", "complex expression"),
      ("10+2*3", "multi-digit numbers"),
    ];

    print("Test Results with DSL-defined Precedence (Forest Parsing):");
    print("━" * 60);

    for (var (String expr, String description) in testCases) {
      print("");
      print('✓ "$expr" ($description)');

      try {
        var result = parser.parseAmbiguous(expr, captureTokensAsMarks: true);

        if (result is ParseSuccess) {
          print("  Status: ✓ Success");
          print("  Marks: ${result.result.rawMarks.length}");
        } else if (result is ParseError) {
          print("  Status: ✗ Parse error at position ${result.position}");
        }
      } on Exception catch (e) {
        print("  Exception: $e");
      }
    }

    print("");
    print("━" * 60);
    print("");
    print("Key Observations:");
    print("  • Using parseAmbiguous() for ambiguity detection");
    print("  • Precedence levels (7 for *, 6 for +) prevent ambiguity");
    print("  • Constraints (expr^7, expr^11) enforce operator associativity");
    print("  • Parenthesized expressions (level 11) override precedence rules");
  } on Exception catch (e) {
    print("✗ Error: $e");
    if (e is GrammarFileParseError) {
      print("  Location: Line ${e.line}, Column ${e.column}");
    }
  }
}
