import "package:glush/src/core/list.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:meta/meta.dart";

/// Cache key for memoizing rule call sites (Callers).

@immutable
final class CallerCacheKey {
  CallerCacheKey(
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
      other is CallerCacheKey &&
          _hash == other._hash &&
          rule == other.rule &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          callArgumentsKey == other.callArgumentsKey &&
          predicateStack == other.predicateStack;

  @override
  int get hashCode => _hash;
}
