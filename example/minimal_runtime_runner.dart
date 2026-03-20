import 'generated_minimal_math.dart';

/// Minimal Runtime Runner
///
/// This script uses the self-contained 'generated_minimal_math.dart'
/// to parse and evaluate mathematical expressions.
void main() {
  print('--- Minimal Math Runner ---\n');

  // Initialize the parser with custom semantic actions.
  // We use the action IDs discovered from the generated stubs.
  final parser = MinimalMathParser(
    actions: {
      // Addition: [ [expr, '+'], term ]
      'act:S3:': (String span, List results) {
        if (results case [[[num l, '+'], num r]]) return l + r;
        return null;
      },

      // Subtraction: [ [expr, '-'], term ]
      'act:S9:': (String span, List results) {
        if (results case [[[num l, '-'], num r]]) return l - r;
        return null;
      },

      // Term: number parsing
      'act:S17:': (String span, List results) {
        // span is the matched string of digits
        return num.parse(span);
      },

      // Internal plus() action (merging list of digits)
      // In this grammar, act:S17 already handles the full span,
      // so we can just return the span or results here.
      'act:S21:': (String span, List results) => results,
    },
  );

  final testInputs = ['5', '10+20', '100-50+25', '1+2+3+4+5'];

  for (final input in testInputs) {
    final outcome = parser.parse(input);
    if (outcome is ParseSuccess) {
      print('✓ "$input" = ${outcome.semanticValue}');
    } else if (outcome is ParseError) {
      print('✗ "$input" failed to parse at position ${outcome.position}');
    }
  }
}
