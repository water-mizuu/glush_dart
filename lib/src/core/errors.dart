/// Core error types for Glush parsing
library glush.errors;

/// Exception thrown when there's an error in grammar definition
class GrammarError implements Exception {
  GrammarError(this.message);
  final String message;

  @override
  String toString() => "GrammarError: $message";
}
