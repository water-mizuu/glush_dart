/// Core error types for Glush parsing
library glush.errors;

/// Represents an error that occurs during the construction or validation
/// of a grammar definition.
///
/// This exception is thrown when the grammar structure itself is invalid,
/// such as when a rule references a non-existent pattern, or when
/// circular dependencies are detected in a way that prevents compilation.
/// It ensures that structural issues are caught early in the development
/// cycle, providing a clear error message that points to the specific
/// misconfiguration in the grammar.
class GrammarError implements Exception {
  /// Constructs a new [GrammarError] with the specified descriptive [message].
  ///
  /// This constructor initializes the error with details about why the
  /// grammar validation failed, allowing developers to quickly identify
  /// and resolve structural issues in their grammar definitions.
  GrammarError(this.message);

  /// The descriptive message detailing the nature of the grammar error.
  final String message;

  /// Returns a formatted string representation of the grammar error.
  ///
  /// By prefixing the message with "GrammarError:", this method ensures that
  /// the source of the exception is immediately obvious when printed to the
  /// console or logged, facilitating easier debugging of grammar-related issues.
  @override
  String toString() => "GrammarError: $message";
}
