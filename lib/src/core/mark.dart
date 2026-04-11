/// Mark class for tracking parse positions
library glush.mark;

import "package:glush/src/core/list.dart";
import "package:meta/meta.dart";

@immutable
sealed class Mark {
  const Mark();
  List<Object> toList();
}

class NamedMark implements Mark {
  const NamedMark(this.name, this.position);
  final String name;
  final int position;

  @override
  List<Object> toList() => [name, position];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NamedMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  @override
  String toString() => "NamedMark($name, $position)";
}

class StringMark implements Mark {
  const StringMark(this.value, this.position);
  final String value;
  final int position;

  @override
  List<Object> toList() => [value, position];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StringMark &&
          runtimeType == other.runtimeType &&
          value == other.value &&
          position == other.position;

  @override
  int get hashCode => value.hashCode ^ position.hashCode;

  @override
  String toString() => "StringMark('${_escapeDisplay(value)}', $position)";
}

class LabelStartMark implements Mark {
  const LabelStartMark(this.name, this.position);
  final String name;
  final int position;

  @override
  List<Object> toList() => [name, position];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelStartMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  @override
  String toString() => "LabelStart($name, $position)";
}

class LabelEndMark implements Mark {
  const LabelEndMark(this.name, this.position);
  final String name;
  final int position;

  @override
  List<Object> toList() => [name, position];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LabelEndMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  @override
  String toString() => "LabelEnd($name, $position)";
}

class ExpandingMark implements Mark {
  const ExpandingMark(this.name, this.position);

  final String name;
  final int position;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExpandingMark &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          position == other.position;

  @override
  int get hashCode => name.hashCode ^ position.hashCode;

  @override
  List<Object> toList() => ["expanding", name, position];
}

/// A mark that holds parallel mark streams from a conjunction.
///
/// This allows structural recovery of sub-parse results from each branch
/// of an intersection without duplicating tokens in the final evaluated span.
final class ConjunctionMark implements Mark {
  ConjunctionMark(this.left, this.right, this.position)
    : _hash = Object.hash(ConjunctionMark, left, right, position);

  /// The parallel mark streams from each branch of the conjunction.
  final LazyGlushList<Mark> left;
  final LazyGlushList<Mark> right;

  final int position;
  final int _hash;

  @override
  List<Object> toList() => [
    "con",
    [left, right],
    position,
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConjunctionMark &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          left == other.left &&
          right == other.right;

  @override
  int get hashCode => _hash;

  @override
  String toString() => "ConjunctionMark(($left, $right), $position)";
}

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

extension MarkListExtension on List<Mark> {
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

class NamedMarkVal extends LazyVal<Mark> {
  const NamedMarkVal(this.name, this.position);
  final String name;
  final int position;

  @override
  Mark evaluate() => NamedMark(name, position);

  @override
  String toString() => "NamedMark($name, $position)";
}

class StringMarkVal extends LazyVal<Mark> {
  const StringMarkVal(this.value, this.position);
  final String value;
  final int position;

  @override
  Mark evaluate() => StringMark(value, position);

  @override
  String toString() => "StringMark($value, $position)";
}

class LabelStartVal extends LazyVal<Mark> {
  const LabelStartVal(this.name, this.position);
  final String name;
  final int position;

  @override
  Mark evaluate() => LabelStartMark(name, position);

  @override
  String toString() => "LabelStart($name, $position)";
}

class LabelEndVal extends LazyVal<Mark> {
  const LabelEndVal(this.name, this.position);
  final String name;
  final int position;

  @override
  Mark evaluate() => LabelEndMark(name, position);

  @override
  String toString() => "LabelEnd($name, $position)";
}

class ExpandingMarkVal extends LazyVal<Mark> {
  const ExpandingMarkVal(this.name, this.position);
  final String name;
  final int position;

  @override
  Mark evaluate() => ExpandingMark(name, position);

  @override
  String toString() => "ExpandingMark($name, $position)";
}
