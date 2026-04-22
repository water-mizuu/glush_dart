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

/// Extensions for converting a list of marks into a more readable format.
extension MarkListExtension on List<Mark> {
  /// Condenses a mark stream into a list of names and matched text.
  ///
  /// It provides a high-level "summary" of what was matched, which is very useful
  /// for verifying the basic structure of a parse result without diving into
  /// every individual mark.
  List<String> toShortMarks() {
    var result = <String>[];

    for (var mark in this) {
      if (mark is LabelStartMark) {
        result.add(mark.name);
      }
    }

    return result;
  }
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
