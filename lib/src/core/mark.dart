/// Mark class for tracking parse positions
library glush.mark;

import "package:glush/src/core/list.dart";
import "package:meta/meta.dart";

/// The base class for all semantic indicators produced during a parse.
///
/// Marks represent significant events or structures identified in the input
/// stream, such as the consumption of a specific terminal, the start or end
/// of a labeled region, or the occurrence of a named capture. By recording
/// these events as a linear stream of marks, the parser can later reconstruct
/// a structured representation (like a parse tree) without having to re-run
/// the full parsing logic.
@immutable
sealed class Mark {
  /// Base constructor for all mark types.
  const Mark();

  /// Converts the mark into a list-based representation for serialization or comparison.
  ///
  /// This method is used to provide a consistent way to represent different mark types
  /// in a format that is easy to store, transmit, or compare against expectations
  /// in test suites.
  List<Object> toList();
}

/// A mark representing a named capture or event at a specific input position.
///
/// Named marks are used to tag specific points in the parse stream with a
/// descriptive identifier, typically corresponding to a capture group or a
/// significant structural boundary.
class NamedMark implements Mark {
  /// Creates a [NamedMark] with the given [name] and [position].
  ///
  /// This constructor is used when the parser encounters a pattern that explicitly
  /// requests a named mark to be recorded in the output stream.
  const NamedMark(this.name, this.position);

  /// The unique identifier or tag associated with this mark.
  final String name;

  /// The zero-based index in the input stream where this mark was recorded.
  final int position;

  /// Returns a list containing the name and position of this mark.
  ///
  /// This implementation allows for easy comparison and debugging by representing
  /// the mark's key data in a standard list format.
  @override
  List<Object> toList() => [name, position];

  /// Checks if this mark is equal to another object based on its name and position.
  ///
  /// Structural equality is essential for verifying parse results in tests and
  /// for ensuring that identical parse paths are treated as such during evaluation.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NamedMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  /// Generates a hash code derived from the name and position.
  ///
  /// This allows the mark to be used effectively in hash-based collections like
  /// sets and maps, which is important for deduplication and caching.
  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  /// Returns a string representation of the named mark for debugging purposes.
  ///
  /// The output format "NamedMark(name, position)" provides a quick way to
  /// inspect the mark's contents in logs or error messages.
  @override
  String toString() => "NamedMark($name, $position)";
}

/// A mark representing the consumption of a literal string from the input.
///
/// String marks record the actual text that was matched by a terminal pattern,
/// along with its starting position. They are the primary way that the results
/// of terminal matching are preserved in the mark stream.
class StringMark implements Mark {
  /// Creates a [StringMark] for the matched [value] at the given [position].
  ///
  /// This is typically instantiated by the parser whenever a string terminal
  /// or a regex terminal successfully matches a portion of the input.
  const StringMark(this.value, this.position);

  /// The literal string value that was matched in the input.
  final String value;

  /// The zero-based index in the input stream where the match began.
  final int position;

  /// Returns a list containing the matched value and its position.
  ///
  /// This serialization allows for consistent comparison of matched content
  /// across different parse results.
  @override
  List<Object> toList() => [value, position];

  /// Compares this string mark to another for structural equality.
  ///
  /// Two string marks are considered equal if they represent the same matched
  /// text at the same input position.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StringMark &&
          runtimeType == other.runtimeType &&
          value == other.value &&
          position == other.position;

  /// Computes a hash code based on the matched value and its position.
  ///
  /// This ensures that equivalent matches are treated identically when stored
  /// in sets or used as keys in maps.
  @override
  int get hashCode => value.hashCode ^ position.hashCode;

  /// Returns a string representation of the matched value, with special characters escaped.
  ///
  /// The use of [_escapeDisplay] ensures that non-printable or ambiguous characters
  /// (like newlines or tabs) are rendered clearly for debugging.
  @override
  String toString() => "StringMark('${_escapeDisplay(value)}', $position)";
}

/// A mark signaling the beginning of a labeled structural element.
///
/// Label marks are used to wrap a sequence of other marks, providing context
/// about the higher-level grammar rule or pattern that produced them.
/// A [LabelStartMark] marks the "opening bracket" of such a structure.
class LabelStartMark implements Mark {
  /// Creates a [LabelStartMark] with the given [name] and [position].
  ///
  /// The [name] typically corresponds to the name of the rule or the label
  /// applied to a specific sub-pattern.
  const LabelStartMark(this.name, this.position);

  /// The name of the label or rule being entered.
  final String name;

  /// The input position where the labeled section begins.
  final int position;

  /// Returns a list containing the label name and its start position.
  @override
  List<Object> toList() => [name, position];

  /// Compares this start mark to another for equality.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelStartMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  /// Generates a hash code for use in collections.
  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  /// Returns a string identifying this as a label start event.
  @override
  String toString() => "LabelStart($name, $position)";
}

/// A mark signaling the end of a labeled structural element.
///
/// This mark serves as the "closing bracket" corresponding to a previous
/// [LabelStartMark], allowing the evaluator to correctly nest and structure
/// the final parse result.
class LabelEndMark implements Mark {
  /// Creates a [LabelEndMark] with the given [name] and [position].
  ///
  /// The [name] must match the corresponding [LabelStartMark]'s name to
  /// maintain structural integrity.
  const LabelEndMark(this.name, this.position);

  /// The name of the label or rule being exited.
  final String name;

  /// The input position where the labeled section ends.
  final int position;

  /// Returns a list containing the label name and its end position.
  @override
  List<Object> toList() => [name, position];

  /// Compares this end mark to another for equality.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelEndMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  /// Generates a hash code for use in collections.
  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  /// Returns a string identifying this as a label end event.
  @override
  String toString() => "LabelEnd($name, $position)";
}

/// A mark used during the expansion of recursive or complex patterns.
///
/// Expanding marks are temporary indicators used by the parser to track
/// progress through potentially nested or repeating structures that haven't
/// yet finalized their internal mark stream.
class ExpandingMark implements Mark {
  /// Creates an [ExpandingMark] with the given [name] and [position].
  const ExpandingMark(this.name, this.position);

  /// The name of the pattern currently being expanded.
  final String name;

  /// The position in the input where the expansion started.
  final int position;

  /// Compares this expanding mark to another for equality.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExpandingMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  /// Generates a hash code for use in collections.
  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  /// Returns a list representation, identifying it specifically as an "expanding" mark.
  @override
  List<Object> toList() => ["expanding", name, position];
}

/// A mark that holds parallel mark streams from a conjunction.
///
/// This allows structural recovery of sub-parse results from each branch
/// of an intersection without duplicating tokens in the final evaluated span.
/// A mark that holds parallel mark streams from a conjunction.
///
/// This allows structural recovery of sub-parse results from each branch
/// of an intersection without duplicating tokens in the final evaluated span.
/// It is essential for correctly representing the dual nature of conjunctions,
/// where multiple patterns must match the same input range.
final class ConjunctionMark implements Mark {
  /// Creates a [ConjunctionMark] that merges the [left] and [right] mark streams.
  ///
  /// The [position] indicates where this conjunction was finalized in the input.
  /// The internal hash is pre-computed to speed up comparisons in complex forests.
  ConjunctionMark(this.left, this.right, this.position)
    : _hash = Object.hash(ConjunctionMark, left, right, position);

  /// The parallel mark streams from the left branch of the conjunction.
  final LazyGlushList<Mark> left;

  /// The parallel mark streams from the right branch of the conjunction.
  final LazyGlushList<Mark> right;

  /// The zero-based index in the input where the conjunction was completed.
  final int position;

  /// Pre-computed hash code for efficiency.
  final int _hash;

  /// Returns a list representation of the conjunction mark.
  ///
  /// This includes the identifier "con", the two sub-streams, and the position,
  /// facilitating deep comparison of conjunction results.
  @override
  List<Object> toList() => [
    "con",
    [left, right],
    position,
  ];

  /// Checks for equality between two conjunction marks.
  ///
  /// Two conjunctions are equal if they share the same position and identical
  /// sub-streams for both branches.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConjunctionMark &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          left == other.left &&
          right == other.right;

  /// Returns the pre-computed hash code for this mark.
  @override
  int get hashCode => _hash;

  /// Returns a string representation of the conjunction and its sub-streams.
  @override
  String toString() => "ConjunctionMark(($left, $right), $position)";
}

/// Escapes a string for clear display in logs and debug output.
///
/// This helper function traverses the string's runes and replaces non-printable
/// or ambiguous characters with their escaped representations (e.g., `\n`, `\t`, `\s`).
/// It ensures that the output remains readable and unambiguous even when the
/// matched text contains whitespace or control characters.
String _escapeDisplay(String value) {
  var out = StringBuffer();
  for (var rune in value.runes) {
    switch (rune) {
      case 0x5C: // \
        out.write(r"\\");
      case 0x27: // '
        out.write(r"\'");
      case 0x20: // space
        out.write(r"\s");
      case 0x09: // tab
        out.write(r"\t");
      case 0x0A: // newline
        out.write(r"\n");
      case 0x0D: // carriage return
        out.write(r"\r");
      default:
        if (rune < 0x20 || rune == 0x7F) {
          out.write(r"\u{");
          out.write(rune.toRadixString(16));
          out.write("}");
        } else {
          out.write(String.fromCharCode(rune));
        }
    }
  }
  return out.toString();
}

/// Extensions for converting a list of marks into a more readable format.
extension MarkListExtension on List<Mark> {
  /// Condenses a mark stream into a list of names and matched text.
  ///
  /// This method iterates through the mark list, collapsing consecutive [StringMark]s
  /// into single strings and extracting the names from [NamedMark]s and [LabelStartMark]s.
  /// It provides a high-level "summary" of what was matched, which is very useful
  /// for verifying the basic structure of a parse result without diving into
  /// every individual mark.
  List<String> toShortMarks() {
    var result = <String>[];
    String? currentStringMark;

    for (var mark in this) {
      if (mark is NamedMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is LabelStartMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is StringMark) {
        currentStringMark = (currentStringMark ?? "") + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }
}

/// A lazy value that produces a [NamedMark].
///
/// This is used within the parser's internal mark streams to defer the creation
/// of mark objects until they are actually needed during evaluation.
class NamedMarkVal extends LazyVal<Mark> {
  /// Creates a [NamedMarkVal] with the given [name] and [position].
  const NamedMarkVal(this.name, this.position);

  /// The name of the mark to be created.
  final String name;

  /// The position of the mark to be created.
  final int position;

  /// Produces the concrete [NamedMark] instance.
  @override
  Mark evaluate() => NamedMark(name, position);

  /// Returns a string representation of this lazy value.
  @override
  String toString() => "NamedMark($name, $position)";
}

/// A lazy value that produces a [StringMark].
///
/// Deferring the creation of string marks helps reduce memory pressure and
/// object allocation overhead during the heavy-lifting phase of parsing.
class StringMarkVal extends LazyVal<Mark> {
  /// Creates a [StringMarkVal] with the given [value] and [position].
  const StringMarkVal(this.value, this.position);

  /// The matched string value.
  final String value;

  /// The position where the match occurred.
  final int position;

  /// Produces the concrete [StringMark] instance.
  @override
  Mark evaluate() => StringMark(value, position);

  /// Returns a string representation of this lazy value.
  @override
  String toString() => "StringMark($value, $position)";
}

/// A lazy value that produces a [LabelStartMark].
///
/// Using lazy evaluation for labels ensures that structural boundaries are
/// only instantiated when the parse tree is being constructed.
class LabelStartVal extends LazyVal<Mark> {
  /// Creates a [LabelStartVal] with the given [name] and [position].
  const LabelStartVal(this.name, this.position);

  /// The name of the label.
  final String name;

  /// The position where the label starts.
  final int position;

  /// Produces the concrete [LabelStartMark] instance.
  @override
  Mark evaluate() => LabelStartMark(name, position);

  /// Returns a string representation of this lazy value.
  @override
  String toString() => "LabelStart($name, $position)";
}

/// A lazy value that produces a [LabelEndMark].
class LabelEndVal extends LazyVal<Mark> {
  /// Creates a [LabelEndVal] with the given [name] and [position].
  const LabelEndVal(this.name, this.position);

  /// The name of the label.
  final String name;

  /// The position where the label ends.
  final int position;

  /// Produces the concrete [LabelEndMark] instance.
  @override
  Mark evaluate() => LabelEndMark(name, position);

  /// Returns a string representation of this lazy value.
  @override
  String toString() => "LabelEnd($name, $position)";
}

/// A lazy value that produces an [ExpandingMark].
class ExpandingMarkVal extends LazyVal<Mark> {
  /// Creates an [ExpandingMarkVal] with the given [name] and [position].
  const ExpandingMarkVal(this.name, this.position);

  /// The name of the pattern being expanded.
  final String name;

  /// The position where the expansion started.
  final int position;

  /// Produces the concrete [ExpandingMark] instance.
  @override
  Mark evaluate() => ExpandingMark(name, position);

  /// Returns a string representation of this lazy value.
  @override
  String toString() => "ExpandingMark($name, $position)";
}
