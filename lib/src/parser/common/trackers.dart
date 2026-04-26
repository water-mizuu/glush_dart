import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/key/parse_node_key.dart";

/// A parked continuation representing a parse path waiting for a sub-parse to complete.
typedef Waiter<S> = (ParseNodeKey?, Context, S, LazyGlushList<Mark>);

/// Base class for coordinating asynchronous or non-linear sub-parses.
sealed class SubparseTracker<S> {
  /// Parked continuations waiting for this sub-parse to complete.
  final List<Waiter<S>> waiters = [];
}

/// Coordinates the execution of a lookahead predicate (&pattern or !pattern).
///
/// A [PredicateTracker] ensures that a lookahead sub-parse is only initiated
/// once for a given (pattern, position) pair.
///
/// If any branch completes successfully, the predicate is marked as [matched].
/// When all branches are finished, the predicate is marked as [exhausted].
/// Parked continuations ([waiters]) are resumed based on whether the predicate
/// was an "AND" (resume on match) or a "NOT" (resume on exhaustion without match).
class PredicateTracker<S> extends SubparseTracker<S> {
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;

  bool matched = false;
  bool exhausted = false;
  int? longestMatch;

  @override
  String toString() => "pred($symbol @ $startPosition)";
}
