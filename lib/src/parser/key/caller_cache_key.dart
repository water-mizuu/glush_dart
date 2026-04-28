import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Cache key for memoizing rule call sites (Callers).
@immutable
final class CallerCacheKey {
  const CallerCacheKey(this.symbol, this.startPosition, this.minPrecedenceLevel);

  final PatternSymbol symbol;
  final int startPosition;
  final int? minPrecedenceLevel;

  @override
  bool operator ==(Object other) =>
      other is CallerCacheKey &&
      symbol == other.symbol &&
      startPosition == other.startPosition &&
      minPrecedenceLevel == other.minPrecedenceLevel;

  @override
  int get hashCode => Object.hash(symbol, startPosition, minPrecedenceLevel);
}
