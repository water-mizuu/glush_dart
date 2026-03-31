import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Key for tracking lookahead predicate sub-parses by pattern and start position.
@immutable
class PredicateKey {
  const PredicateKey(this.pattern, this.startPosition);
  final PatternSymbol pattern;
  final int startPosition;

  @override
  bool operator ==(Object other) =>
      other is PredicateKey && pattern == other.pattern && startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(pattern, startPosition);

  @override
  String toString() => "pred($pattern @ $startPosition)";
}

/// Partner-end rendezvous for negations (!pattern).
/// Used to track where a negative lookahead began.
@immutable
class NegationKey {
  const NegationKey(this.pattern, this.startPosition);
  final PatternSymbol pattern;
  final int startPosition;

  @override
  bool operator ==(Object other) =>
      other is NegationKey && pattern == other.pattern && startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(pattern, startPosition);
}

/// Key for tracking conjunction sub-parses by left/right patterns and start position.
@immutable
class ConjunctionKey {
  const ConjunctionKey(this.left, this.right, this.startPosition);
  final PatternSymbol left;
  final PatternSymbol right;
  final int startPosition;

  @override
  bool operator ==(Object other) =>
      other is ConjunctionKey &&
      left == other.left &&
      right == other.right &&
      startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(left, right, startPosition);
}
