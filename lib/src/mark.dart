/// Mark class for tracking parse positions
library glush.mark;

sealed class Mark {}

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
  String toString() => 'StringMark($value, $position)';
}
