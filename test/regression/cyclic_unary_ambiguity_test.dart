import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  test("Cyclic unary ambiguity does not cause infinite loop", () {
    // Grammar with cyclic unary structure: S = $1 (S) | $2 's'
    // This represents a pattern where S can be a labeled S wrapped,
    // or the terminal 's'. This created infinite loop with cyclic unary ambiguity
    // before the Strict Span Deduplication fix.

    const grammarSource = r"""
S = $1 (S) | $2 's'
""";

    var parser = grammarSource.toSMParser();

    // This should parse the input synchronously and not hang.
    var result = parser.parse("s");

    // The parser should successfully parse the input
    expect(result, isA<ParseSuccess>(), reason: "Parser should complete without hanging");
  });

  test("Cyclic unary ambiguity with ambiguous parsing", () {
    // Test with ambiguous parsing to check that marks are still enumerated
    const grammarSource = r"""
S = $1 (S) | $2 's'
""";

    var parser = grammarSource.toSMParser();

    var result = parser.parseAmbiguous("s");

    expect(
      result,
      isA<ParseAmbiguousSuccess>(),
      reason: "Ambiguous parser should complete without hanging",
    );

    if (result is ParseAmbiguousSuccess) {
      var paths = result.forest.allPaths().toList();
      // Should have paths representing different derivations
      expect(paths.length, greaterThan(0), reason: "Should have at least one derivation");
      expect(
        paths.length,
        lessThan(1000),
        reason: "Should not have exponential explosion of paths due to span deduplication",
      );
    }
  });

  test("Cyclic unary ambiguity with multiple alternatives", () {
    // More complex variant: S can recurse or parse 's' or 't'
    const grammarSource = r"""
S = $1 (S) | $2 (S) | $3 's' | $4 't'
""";

    var parser = grammarSource.toSMParser();

    // Parse simple inputs - should complete quickly despite cyclic structure
    for (var input in ["s", "t"]) {
      var result = parser.parse(input);
      expect(result, isA<ParseSuccess>(), reason: "Should parse '$input' without hanging");
    }
  });

  test("Strict Span Deduplication prevents duplicate derivations", () {
    // Test that demonstrates the deduplication is working
    // Without proper span deduplication, this would create exponential
    // duplicate parse states and hang
    const grammarSource = r"""
S = $1 (S) | $2 's'
""";

    var parser = grammarSource.toSMParser();

    // Parse and check that we can successfully collect results
    var result = parser.parseAmbiguous("s");

    expect(result, isA<ParseAmbiguousSuccess>());

    if (result is ParseAmbiguousSuccess) {
      var paths = result.forest.allPaths().toList();
      print(paths);
      // Should have a reasonable number of paths, not exponential explosion
      expect(paths.length, greaterThan(0));
      expect(
        paths.length,
        lessThan(1000),
        reason: "Should not have exponential explosion of paths due to span deduplication",
      );

      // Verify that we can enumerate and evaluate paths
      for (var path in paths) {
        expect(path, isNotEmpty, reason: "Each path should have marks");
      }
    }
  });
}
