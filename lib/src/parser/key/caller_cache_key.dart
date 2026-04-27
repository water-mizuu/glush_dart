import "package:glush/src/core/list.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/key/caller_key.dart";

/// Cache key for memoizing rule call sites (Callers).
extension type const CallerCacheKey._(
  (
    Rule rule,
    int startPosition,
    int? minPrecedenceLevel,
    GlushList<PredicateCallerKey> predicateStack,
  )
  data
) {
  const CallerCacheKey(
    Rule rule,
    int startPosition,
    int? minPrecedenceLevel,
    GlushList<PredicateCallerKey> predicateStack,
  ) : this._((rule, startPosition, minPrecedenceLevel, predicateStack));

  Rule get rule => data.$1;
  int get startPosition => data.$2;
  int? get minPrecedenceLevel => data.$3;
  GlushList<PredicateCallerKey> get predicateStack => data.$4;
}
