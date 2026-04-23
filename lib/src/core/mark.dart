import "package:glush/src/core/list.dart";
import "package:meta/meta.dart";

/// Interface for values that can be shifted by an integer delta (e.g. for position updates).
abstract interface class Shiftable<T> {
  /// Returns a copy of this object with its positions shifted by [delta].
  T shifted(int delta);
}

/// The base class for all semantic indicators produced during a parse.
///
/// Marks represent significant events or structures identified in the input
/// stream. They no longer store absolute positions, making them position-independent
/// and allowing for efficient subtree reuse without coordinate shifting.
@immutable
sealed class Mark {
  const Mark();

  List<Object> toList();
}

/// A mark signaling the beginning of a labeled structural element.
class LabelStartMark implements Mark {
  const LabelStartMark(this.name, [this.position]);

  final String name;
  final int? position;

  @override
  List<Object> toList() => [name, position ?? -1];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelStartMark && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => "LabelStart($name)";
}

/// A mark signaling the end of a labeled structural element.
class LabelEndMark implements Mark {
  const LabelEndMark(this.name, [this.position]);

  final String name;
  final int? position;

  @override
  List<Object> toList() => [name, position ?? -1];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelEndMark && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => "LabelEnd($name)";
}

/// A mark representing a single consumed character/token or a group of characters.
class TokenMark implements Mark {
  const TokenMark(this.token, [this.length = 1]);
  final int token;
  final int length;

  @override
  List<Object> toList() => ["token", token, length];

  @override
  bool operator ==(Object other) =>
      other is TokenMark && token == other.token && length == other.length;

  @override
  int get hashCode => Object.hash(token, length);

  @override
  String toString() => "Token($token, len=$length)";
}

/// A mark used during the expansion of recursive or complex patterns.
class ExpandingMark implements Mark {
  const ExpandingMark(this.name);
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExpandingMark && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;

  @override
  List<Object> toList() => ["expanding", name];
}

/// Extensions for converting a list of marks into a more readable format.
extension MarkListExtension on List<Mark> {
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
class LabelStartVal extends LazyVal<Mark> {
  const LabelStartVal(this.name, [this.position]);
  final String name;
  final int? position;

  @override
  Mark evaluate() => LabelStartMark(name, position);

  @override
  String toString() => "LabelStart($name)";
}

/// A lazy value that produces a [LabelEndMark].
class LabelEndVal extends LazyVal<Mark> {
  const LabelEndVal(this.name, [this.position]);
  final String name;
  final int? position;

  @override
  Mark evaluate() => LabelEndMark(name, position);

  @override
  String toString() => "LabelEnd($name)";
}

/// A lazy value that produces an [ExpandingMark].
class ExpandingMarkVal extends LazyVal<Mark> {
  const ExpandingMarkVal(this.name);
  final String name;

  @override
  Mark evaluate() => ExpandingMark(name);

  @override
  String toString() => "ExpandingMark($name)";
}
