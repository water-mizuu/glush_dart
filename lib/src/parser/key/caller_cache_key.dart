import "package:glush/src/core/patterns.dart";

/// Cache key for memoizing rule call sites (Callers).
extension type const CallerCacheKey._(
  (PatternSymbol symbol, int startPosition, int? minPrecedenceLevel) data
) {
  const CallerCacheKey(PatternSymbol symbol, int startPosition, int? minPrecedenceLevel)
    : this._((symbol, startPosition, minPrecedenceLevel));

  PatternSymbol get symbol => data.$1;
  int get startPosition => data.$2;
  int? get minPrecedenceLevel => data.$3;
}
