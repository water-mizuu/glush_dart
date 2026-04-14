import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A parked continuation for a sub-parse.
///
/// Contains the derivation source, the parent context to resume in,
/// and the next state to transition to.
typedef Waiter = (ParseNodeKey?, Context, State, LazyGlushList<Mark>);

/// Base class for tracking asynchronous sub-parses (predicates, conjunctions).
sealed class SubparseTracker {
  /// How many frames owned by this sub-parse are currently in flight.
  int activeFrames = 0;

  /// Parked continuations waiting for this sub-parse to complete.
  final List<Waiter> waiters = [];

  /// Mark one sub-parse-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one sub-parse-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      "$runtimeType underflow: removePendingFrame() called with no pending frames.",
    );
    activeFrames--;
  }

  /// True when the sub-parse has no more work to do.
  bool get isExhausted => activeFrames == 0;
}

/// Tracks one lookahead sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same predicate from multiple branches, so the
/// tracker counts how many predicate-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the predicate as matched
/// or exhausted, and then wake any parked continuations.
class PredicateTracker extends SubparseTracker {
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;

  bool matched = false;
  bool exhausted = false;
  int? longestMatch;

  /// True when the predicate can no longer succeed and has not matched.
  bool get canResolveFalse => !matched && !exhausted && activeFrames == 0;

  @override
  String toString() => "pred($symbol @ $startPosition)";
}

/// Tracks one consuming conjunction sub-parse (intersection) for `(left, right, startPosition)`.
///
/// Both sides (A and B) are run independently from the same start position.
/// When both find a match ending at the same position `j`, they rendezvous
/// and resume the main parse at `j`.
class ConjunctionTracker extends SubparseTracker {
  ConjunctionTracker({
    required this.leftSymbol,
    required this.rightSymbol,
    required this.startPosition,
  });
  final PatternSymbol leftSymbol;
  final PatternSymbol rightSymbol;
  final int startPosition;

  final Map<int, List<LazyGlushList<Mark>>> leftCompletions = {};
  final Map<int, List<LazyGlushList<Mark>>> rightCompletions = {};

  @override
  String toString() => "conj($leftSymbol & $rightSymbol @ $startPosition)";
}
