import "dart:math" show max;

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";

/// Sealed result type returned by parser.parse().
sealed class ParseOutcome {
  ParseError? error();
  ParseSuccess? success();
  ParseAmbiguousSuccess? ambiguousSuccess();
}

/// Returned when parsing fails.
final class ParseError implements ParseOutcome, Exception {
  const ParseError(this.position);
  final int position;

  @override
  String toString() => "ParseError at position $position";

  @override
  ParseError error() => this;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess? ambiguousSuccess() => null;

  void displayError(String input) {
    if (input.isEmpty) {
      throw StateError("Input string is empty.");
    }
    if (position < 0 || position > input.length) {
      throw RangeError("Error position is out of bounds.");
    }

    // 1. Efficiently calculate row and column in one pass (No heavy substrings/splits)
    int row = 1;
    int lineStartIndex = 0;

    for (int i = 0; i < position; i++) {
      if (input[i] == "\n") {
        row++;
        lineStartIndex = i + 1; // Mark where the current line started
      }
    }

    // Column is simply the distance from the start of the line to the error,
    // ignoring \r if we are on a Windows-style file.
    String textBeforeErrorOnLine = input.substring(lineStartIndex, position);
    int column = textBeforeErrorOnLine.replaceAll("\r", "").length + 1;

    // 2. Prepare visual output context
    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    // Grab up to 3 lines of context.
    List<(int, String)> displayedRows = inputRows.indexed
        .skip(max(row - 3, 0))
        .take(3) // Ensure we only take the relevant slice
        .toList();

    int longest = displayedRows.map((e) => (e.$1 + 1).toString().length).reduce(max);

    // 3. Print the formatted output
    print("Parse error at: ($row:$column)");

    for (var (i, v) in displayedRows) {
      String lineNumber = (i + 1).toString().padLeft(longest);
      print(" $lineNumber | $v");
    }

    // Calculate exactly how many spaces the caret needs
    // Formula: 1 starting space + length of longest line number + 3 for " | " + column - 1
    int gutterWidth = 1 + longest + 3;
    int caretPadding = gutterWidth + (column - 1);

    print("${' ' * caretPadding}^");
  }
}

/// Returned when parsing succeeds (marks-based parse).
final class ParseSuccess implements ParseOutcome {
  const ParseSuccess(this.result);
  final ParserResult result;

  @override
  ParseError? error() => null;

  @override
  ParseSuccess success() => this;

  @override
  ParseAmbiguousSuccess? ambiguousSuccess() => null;
}

/// Returned when parsing succeeds with an ambiguous forest.
final class ParseAmbiguousSuccess implements ParseOutcome {
  const ParseAmbiguousSuccess(this.forest);
  final LazyGlushList<Mark> forest;

  @override
  ParseError? error() => null;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess ambiguousSuccess() => this;
}

/// Holds the results of a basic parse() operation.
///
/// Provides methods to extract flattened mark streams and human-readable
/// representations of the categorical annotations found during parsing.
class ParserResult {
  const ParserResult(this._rawMarks);
  final List<Mark> _rawMarks;

  List<Mark> get rawMarks => _rawMarks;

  List<String> get marks {
    var result = <String>[];
    StringBuffer? currentStringMark;

    for (var mark in _rawMarks) {
      // Dispatch by mark kind to rebuild a human-readable flattened stream.
      if (mark is NamedMark) {
        // Named marks break string runs, so flush buffered token text first.
        if (currentStringMark != null) {
          result.add(currentStringMark.toString());
          currentStringMark = null;
        }
        result.add(mark.name);
        // Label starts are emitted as their own marker entries.
      } else if (mark is LabelStartMark) {
        // Label boundaries also break string runs for stable mark segmentation.
        if (currentStringMark != null) {
          result.add(currentStringMark.toString());
          currentStringMark = null;
        }
        result.add(mark.name);
        // Raw token text contributes to the currently buffered string chunk.
      } else if (mark is StringMark) {
        // Adjacent token chars are merged into one logical text chunk.
        currentStringMark ??= StringBuffer();
        currentStringMark.write(mark.value);
      }
    }
    // Flush trailing string chunk, if any.
    if (currentStringMark != null) {
      // Flush trailing buffered text after the loop ends.
      result.add(currentStringMark.toString());
    }

    return result;
  }

  List<List<Object?>> toList() => _rawMarks.map((m) => m.toList()).toList();
}
