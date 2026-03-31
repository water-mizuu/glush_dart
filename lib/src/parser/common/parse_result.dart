import "dart:math" show max;

import "package:glush/src/core/list.dart" show GlushList;
import "package:glush/src/core/mark.dart" show LabelStartMark, Mark, NamedMark, StringMark;
import "package:glush/src/representation/sppf.dart" show ParseForest;

/// Sealed result type returned by parser.parse().
sealed class ParseOutcome {
  ParseError? error();
  ParseSuccess? success();
  ParseAmbiguousSuccess? ambiguousSuccess();
  ParseForestSuccess? forestSuccess();
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

  @override
  ParseForestSuccess? forestSuccess() => null;

  void displayError(String input) {
    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    /// Surely the string we're trying to parse is not empty.
    if (inputRows.isEmpty) {
      throw StateError("Huh?");
    }

    int row = input.substring(0, position).split("\n").length;
    int column =
        input //
            .substring(0, position)
            .split("\n")
            .last
            .codeUnits
            .length +
        1;
    List<(int, String)> displayedRows = inputRows.indexed.toList().sublist(max(row - 3, 0), row);

    int longest = displayedRows.map((e) => e.$1.toString().length).reduce(max);

    print("Parse error at: ($row:$column)");
    print(
      displayedRows
          .map(
            (v) =>
                " ${(v.$1 + 1).toString().padLeft(longest)} | "
                "${v.$2}",
          )
          .join("\n"),
    );
    print("${" " * " ${''.padLeft(longest)} | ".length}${' ' * (column - 1)}^");
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

  @override
  ParseForestSuccess? forestSuccess() => null;
}

/// Returned when parsing succeeds with an ambiguous forest.
final class ParseAmbiguousSuccess implements ParseOutcome {
  const ParseAmbiguousSuccess(this.forest);
  final GlushList<Mark> forest;

  @override
  ParseError? error() => null;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess ambiguousSuccess() => this;

  @override
  ParseForestSuccess? forestSuccess() => null;
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess implements ParseOutcome {
  const ParseForestSuccess(this.forest);
  final ParseForest forest;

  @override
  String toString() => "ParseForestSuccess(forest=$forest)";

  @override
  ParseError? error() => null;

  @override
  ParseSuccess? success() => null;

  @override
  ParseAmbiguousSuccess? ambiguousSuccess() => null;

  @override
  ParseForestSuccess forestSuccess() => this;
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
