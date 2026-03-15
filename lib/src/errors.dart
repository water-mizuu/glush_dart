/// Core error types for Glush parsing
library glush.errors;

/// Exception thrown when there's an error in grammar definition
class GrammarError implements Exception {
  final String message;

  GrammarError(this.message);

  @override
  String toString() => 'GrammarError: $message';
}
