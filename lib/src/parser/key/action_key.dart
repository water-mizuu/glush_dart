import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Base class for all sub-parse tracking keys.
@immutable
abstract class SubparseKey {
  const SubparseKey();
}

/// Key for tracking lookahead predicate sub-parses by pattern and start position.
@immutable
class PredicateKey extends SubparseKey {
  const PredicateKey(this.pattern, this.startPosition, {required this.isAnd, this.name});
  final PatternSymbol pattern;
  final int startPosition;
  final bool isAnd;
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is PredicateKey &&
      pattern == other.pattern &&
      startPosition == other.startPosition &&
      isAnd == other.isAnd &&
      name == other.name;

  @override
  int get hashCode => Object.hash(pattern, startPosition, isAnd, name);

  @override
  String toString() {
    var desc = name != null ? "($name:$pattern)" : "($pattern)";
    var prefix = isAnd ? "&" : "!";
    return "pred($prefix$desc @ $startPosition)";
  }
}
