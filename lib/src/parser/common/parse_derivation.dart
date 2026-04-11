import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";

// ---------------------------------------------------------------------------

/// Represents a single parse tree derivation.
///
/// An immutable tree structure representing one complete parse of the input.
/// Each node contains a symbol, span [start:end], and child derivations.
/// Used by enumeration methods and for evaluating semantic values.
/// Supports conversion to strings and precedence analysis.
class ParseDerivation {
  /// Creates a parse derivation for a symbol spanning [start] to [end].
  const ParseDerivation(this.symbol, this.start, this.end, this.children);

  /// The grammar symbol or pattern that this node represents.
  final PatternSymbol symbol;

  /// Start position in the input where this derivation begins.
  final int start;

  /// End position in the input where this derivation ends.
  final int end;

  /// Child derivations for the child symbols of this pattern.
  final List<ParseDerivation> children;

  /// Returns the substring of the input that this derivation matched.
  /// Safe for out-of-bounds positions.
  String getMatchedText(String input) {
    if (input.isEmpty || start >= input.length) {
      return "";
    }
    var actualEnd = end > input.length ? input.length : end;
    return input.substring(start, actualEnd);
  }

  /// Converts the derivation tree to a formatted string with indentation.
  /// Useful for debugging and visualizing parse trees.
  String toTreeString(String input, [int indent = 0]) {
    var prefix = "  " * indent;
    var str = '$prefix$this${children.isEmpty ? '  ${input.substring(start, end)}' : ''}\n';
    return str + children.map((c) => c.toTreeString(input, indent + 1)).join();
  }

  /// Converts the derivation to a parenthesized string representation.
  /// Useful for displaying operator precedence structure.
  String toPrecedenceString(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    List<String> mapped = children
        .where((c) => c.start != c.end)
        .map((c) => c.toPrecedenceString(input))
        .toList();

    if (mapped.length == 1) {
      return mapped.single;
    }

    return "(${mapped.join()})";
  }

  /// Returns a simplified parse tree by collapsing single-child chains.
  /// Useful for removing internal structural nodes from the derivation.
  Object? getSimplified(String input) {
    if (children.isEmpty) {
      return input.substring(start, end);
    }

    if (children.length == 1) {
      return children.single.getSimplified(input);
    }

    return children.map((c) => c.getSimplified(input)).toList();
  }

  /// Returns a compact string representation showing symbol and span.
  @override
  String toString() => "$symbol[$start:$end]";
}

/// Represents a parse tree with its evaluated semantic value.
///
/// Combines a [ParseDerivation] tree with a computed semantic value (T).
/// Provides convenient access to both the tree structure and its evaluated result,
/// useful when iterating over all parse interpretations.
class ParseDerivationWithValue<T> {
  /// Creates a parse derivation with its evaluated semantic value.
  ParseDerivationWithValue(this.tree, this.value, {this.grammar});

  /// The underlying parse tree structure.
  final ParseDerivation tree;

  /// The computed semantic value from evaluating the parse tree.
  final T value;

  /// Optional reference to the grammar for symbol resolution.
  final GrammarInterface? grammar;

  /// Returns the substring of input that this derivation matched.
  String getMatchedText(String input) => tree.getMatchedText(input);

  /// Returns the grammar symbol that this derivation represents.
  PatternSymbol get symbol => tree.symbol;

  /// Returns the resolved pattern object from the grammar registry.
  /// Returns null if grammar is unavailable or the symbol is not registered.
  Pattern? get pattern {
    if (grammar case var grammar?) {
      return grammar.registry[tree.symbol];
    }
    return null;
  }

  /// Returns the start position in the input where this derivation begins.
  int get start => tree.start;

  /// Returns the end position in the input where this derivation ends.
  int get end => tree.end;

  /// Returns the child derivations of this tree node.
  List<ParseDerivation> get children => tree.children;

  /// Returns a string showing the symbol, span, and semantic value.
  @override
  String toString() => "$symbol[$start:$end]=$value";
}
