import "package:glush/src/core/patterns.dart";

extension type const CallerCacheKey._((PatternSymbol, int, int?) data) {
  const CallerCacheKey(PatternSymbol symbol, int startPosition, int? minPrecedenceLevel)
    : this._((symbol, startPosition, minPrecedenceLevel));

  PatternSymbol get symbol => data.$1;
  int get startPosition => data.$2;
  int? get minPrecedenceLevel => data.$3;
}
