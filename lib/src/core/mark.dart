/// Mark class for tracking parse positions
library glush.mark;

sealed class Mark {
  List<Object> toList();
}

class NamedMark extends Mark {
  final String name;
  final int position;

  NamedMark(this.name, this.position);

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
  String toString() => 'NamedMark($name, $position)';
}

class StringMark extends Mark {
  final String value;
  final int position;

  StringMark(this.value, this.position);

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

class LabelStartMark extends Mark {
  final String name;
  final int position;

  LabelStartMark(this.name, this.position);

  @override
  List<Object> toList() => [name, position];

  @override
  String toString() => 'LabelStart($name, $position)';
}

class LabelEndMark extends Mark {
  final String name;
  final int position;

  LabelEndMark(this.name, this.position);

  @override
  List<Object> toList() => [name, position];

  @override
  String toString() => 'LabelEnd($name, $position)';
}

String _escapeDisplay(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C: // \
        out.write(r'\\');
      case 0x27: // '
        out.write(r"\'");
      case 0x20: // space
        out.write(r'\s');
      case 0x09: // tab
        out.write(r'\t');
      case 0x0A: // newline
        out.write(r'\n');
      case 0x0D: // carriage return
        out.write(r'\r');
      default:
        if (rune < 0x20 || rune == 0x7F) {
          out.write(r'\u{');
          out.write(rune.toRadixString(16));
          out.write('}');
        } else {
          out.write(String.fromCharCode(rune));
        }
    }
  }
  return out.toString();
}

extension MarkListExtension on List<Mark> {
  List<String> toShortMarks() {
    final result = <String>[];
    String? currentStringMark;

    for (final mark in this) {
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
        currentStringMark = (currentStringMark ?? '') + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }
}
