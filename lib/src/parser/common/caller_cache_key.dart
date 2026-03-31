import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Cache key for memoizing rule call sites (Callers).
@immutable
sealed class CallerCacheKey {
  static CallerCacheKey create(
    Rule rule,
    int startPosition,
    int? minPrecedenceLevel,
    CallArgumentsKey callArgumentsKey,
  ) {
    if (callArgumentsKey is StringCallArgumentsKey && callArgumentsKey.key.isEmpty) {
      // Bit-pack: StartPos (31) | RuleUID (24) | MinPrec (8)
      // Use 32-bit shift for position to avoid overlap with 24-bit rule ID.
      return IntCallerCacheKey(
        (startPosition << 32) | (rule.uid << 8) | (minPrecedenceLevel ?? 0xFF),
      );
    }
    return ComplexCallerCacheKey(rule, startPosition, minPrecedenceLevel, callArgumentsKey);
  }
}

final class IntCallerCacheKey implements CallerCacheKey {
  IntCallerCacheKey(this.value) : _hash = Object.hash(IntCallerCacheKey, value);
  final int value;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IntCallerCacheKey && value == other.value;

  @override
  int get hashCode => _hash;
}

@immutable
final class ComplexCallerCacheKey implements CallerCacheKey {
  ComplexCallerCacheKey(
    this.rule,
    this.startPosition,
    this.minPrecedenceLevel,
    this.callArgumentsKey,
  ) : _hash = Object.hash(rule, startPosition, minPrecedenceLevel, callArgumentsKey);

  final Rule rule;
  final int startPosition;
  final int? minPrecedenceLevel;
  final CallArgumentsKey callArgumentsKey;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexCallerCacheKey &&
          _hash == other._hash &&
          rule == other.rule &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          callArgumentsKey == other.callArgumentsKey;

  @override
  int get hashCode => _hash;
}
