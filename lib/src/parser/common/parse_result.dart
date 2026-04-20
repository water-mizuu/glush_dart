import "dart:math" show max;

import "package:glush/src/core/list.dart";
import "package:glush/src/core/list_mark_extensions.dart";
import "package:glush/src/core/mark.dart";

/// The base type for all results returned by the parser.
///
/// [ParseOutcome] uses a sealed class hierarchy to represent the different
/// possible results of a parsing operation: error, single-path success, or
/// ambiguous multi-path success.
sealed class ParseOutcome {
  /// Returns the error if the parse failed, or null otherwise.
  ParseError? error();

  /// Returns the successful result if a single path was found, or null otherwise.
  ParseSuccess? success();

  /// Returns the successful result if multiple ambiguous paths were found, or null otherwise.
  ParseAmbiguousSuccess? ambiguousSuccess();
}

/// Represents a failure to parse the input at a specific position.
///
/// [ParseError] implements [Exception] and provides utilities for calculating
/// and displaying the error location in a human-readable format.
final class ParseError implements ParseOutcome, Exception {
  /// Creates a [ParseError] at the given [position] in the input.
  const ParseError(this.position);

  /// The zero-based index in the input stream where the error occurred.
  final int position;

  @override
  String toString() => "ParseError at position $position";

  @override
  ParseError error() => this;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess? ambiguousSuccess() => null;

  /// Prints a formatted error message to the console, showing the input
  /// context around the error.
  ///
  /// This method calculates the line and column number and renders a
  /// visual caret pointing to the exact error location.
  void displayError(String input) {
    if (input.isEmpty) {
      throw StateError("Input string is empty.");
    }
    if (position < 0 || position > input.length) {
      throw RangeError("Error position is out of bounds.");
    }

    int row = 1;
    int lineStartIndex = 0;

    for (int i = 0; i < position; i++) {
      if (input[i] == "\n") {
        row++;
        lineStartIndex = i + 1;
      }
    }

    String textBeforeErrorOnLine = input.substring(lineStartIndex, position);
    int column = textBeforeErrorOnLine.replaceAll("\r", "").length + 1;

    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    List<(int, String)> displayedRows = inputRows.indexed.skip(max(row - 3, 0)).take(3).toList();

    int longest = displayedRows.map((e) => (e.$1 + 1).toString().length).reduce(max);

    print("Parse error at: ($row:$column)");

    for (var (i, v) in displayedRows) {
      String lineNumber = (i + 1).toString().padLeft(longest);
      print(" $lineNumber | $v");
    }

    int gutterWidth = 1 + longest + 3;
    int caretPadding = gutterWidth + (column - 1);

    print("${' ' * caretPadding}^");
  }
}

/// Represents a successful parse where exactly one derivation path was found.
///
/// This result contains the semantic [rawMarks] extracted from the input
final class ParseSuccess implements ParseOutcome {
  /// Creates a [ParseSuccess] with the given [rawMarks].
  const ParseSuccess(this.rawMarks);

  /// The list of semantic marks captured during the parse.
  final List<Mark> rawMarks;

  /// Returns the mark names as a simple list of strings.
  List<String> get marks => rawMarks.toMarkStrings();

  @override
  ParseError? error() => null;

  @override
  ParseSuccess success() => this;

  @override
  ParseAmbiguousSuccess? ambiguousSuccess() => null;
}

/// Represents a successful parse in an ambiguous grammar.
///
/// This result provides the full [forest] of all possible derivation paths
/// represented as a [LazyGlushList] of marks.
final class ParseAmbiguousSuccess implements ParseOutcome {
  ParseAmbiguousSuccess(LazyGlushList<Mark> forest) : this._(MarkForest(forest));

  /// Creates a [ParseAmbiguousSuccess] with the given [forest].
  const ParseAmbiguousSuccess._(this.forest);

  /// The lazy list representing the entire parse forest of semantic marks.
  final MarkForest forest;

  @override
  ParseError? error() => null;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess ambiguousSuccess() => this;
}

class MarkForest with Iterable<List<Mark>> {
  const MarkForest(this.inner);

  final LazyGlushList<Mark> inner;

  int get derivationCount => inner.countDerivations();

  @override
  Iterator<List<Mark>> get iterator => inner.allMarkPaths().iterator;

  Iterable<List<Mark>> allMarkPaths() => inner.allMarkPaths();
  int countDerivations() => inner.countDerivations();
  GlushList<Mark> evaluate() => inner.evaluate();
}
