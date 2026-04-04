import "package:meta/meta.dart";

/// Key for grouping return contexts by metadata, excluding marks.
@immutable
sealed class ReturnKey {
  static int getPackedId(int? precedenceLevel, int? pivot, int? callStart) {
    return (pivot ?? 0) << 32 | (precedenceLevel ?? 0xFFFF) << 16 | (callStart ?? 0xFFFF);
  }

  static ReturnKey create(int? precedenceLevel, int? pivot, int? callStart) {
    return IntReturnKey(getPackedId(precedenceLevel, pivot, callStart));
  }
}

@immutable
final class IntReturnKey implements ReturnKey {
  const IntReturnKey(this.id);
  final int id;

  @override
  bool operator ==(Object other) => other is IntReturnKey && id == other.id;

  @override
  int get hashCode => id;
}

@immutable
final class ComplexReturnKey implements ReturnKey {
  ComplexReturnKey(this.precedenceLevel, this.pivot, this.callStart)
    : _hash = Object.hash(ComplexReturnKey, precedenceLevel, pivot, callStart);

  final int? precedenceLevel;
  final int? pivot;
  final int? callStart;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexReturnKey &&
          _hash == other._hash &&
          precedenceLevel == other.precedenceLevel &&
          pivot == other.pivot &&
          callStart == other.callStart;

  @override
  int get hashCode => _hash;
}
