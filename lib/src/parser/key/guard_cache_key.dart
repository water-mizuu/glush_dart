import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Cache key for guard evaluation results.
///
/// Prevents redundant execution of user-defined guard expressions and rule
/// arguments by memoizing their results at specific input positions.
@immutable
final class GuardCacheKey {
  GuardCacheKey(
    this.rule,
    this.guard,
    // this.marks,
    this.callArgumentsKey,
    this.position,
    this.callStart,
    this.precedenceLevel,
  ) : _hash = Object.hash(
        GuardCacheKey,
        rule,
        guard,
        // marks,
        callArgumentsKey,
        position,
        callStart,
        precedenceLevel,
      );

  final Rule rule;
  final GuardExpr guard;
  // final GlushList<Mark> marks;
  final CallArgumentsKey callArgumentsKey;
  final int position;
  final int? callStart;
  final int? precedenceLevel;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GuardCacheKey && _hash == other._hash;

  @override
  int get hashCode => _hash;
}
