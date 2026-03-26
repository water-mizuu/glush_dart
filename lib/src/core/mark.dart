/// Mark class for tracking parse positions
library glush.mark;

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
