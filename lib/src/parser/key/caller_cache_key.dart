import "package:glush/src/core/list.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:meta/meta.dart";

/// Cache key for memoizing rule call sites (Callers).
@immutable
sealed class CallerCacheKey {
  static CallerCacheKey create(
    Rule rule,
    int startPosition,
    int? minPrecedenceLevel,
    CallArgumentsKey callArgumentsKey,
    GlushList<PredicateCallerKey> predicateStack,
  ) {
    if (callArgumentsKey is StringCallArgumentsKey &&
        callArgumentsKey.key.isEmpty &&
        predicateStack.isEmpty) {
      // Bit-pack: StartPos (31) | RuleUID (24) | MinPrec (8)
      return IntCallerCacheKey(
        (startPosition << 32) | (rule.uid << 8) | (minPrecedenceLevel ?? 0xFF),
      );
    }
    return ComplexCallerCacheKey(
      rule,
      startPosition,
      minPrecedenceLevel,
      callArgumentsKey,
      predicateStack,
    );
  }
}

@immutable
final class IntCallerCacheKey implements CallerCacheKey {
  const IntCallerCacheKey(this.id);
  final int id;

  @override
  bool operator ==(Object other) => other is IntCallerCacheKey && id == other.id;

  @override
  int get hashCode => id;
}

@immutable
final class ComplexCallerCacheKey implements CallerCacheKey {
  ComplexCallerCacheKey(
    this.rule,
    this.startPosition,
    this.minPrecedenceLevel,
    this.callArgumentsKey,
    this.predicateStack,
  ) : _hash = Object.hash(
        rule,
        startPosition,
        minPrecedenceLevel,
        callArgumentsKey,
        predicateStack,
      );

  final Rule rule;
  final int startPosition;
  final int? minPrecedenceLevel;
  final CallArgumentsKey callArgumentsKey;
  final GlushList<PredicateCallerKey> predicateStack;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexCallerCacheKey &&
          _hash == other._hash &&
          rule == other.rule &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          callArgumentsKey == other.callArgumentsKey &&
          predicateStack == other.predicateStack;

  @override
  int get hashCode => _hash;
}
