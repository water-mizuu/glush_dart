import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/state_machine.dart";

/// Tracks one lookahead sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same predicate from multiple branches, so the
/// tracker counts how many predicate-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the predicate as matched
/// or exhausted, and then wake any parked continuations.
class PredicateTracker {
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(ParseNodeKey? source, Context, State)> waiters = [];

  /// Mark one predicate-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one predicate-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      "PredicateTracker underflow: removePendingFrame() called with no pending frames.",
    );
    activeFrames--;
  }

  /// True when the predicate can no longer succeed and has not matched.
  bool get canResolveFalse => !matched && activeFrames == 0;
}

/// Tracks one consuming conjunction sub-parse (intersection) for `(left, right, startPosition)`.
///
/// Both sides (A and B) are run independently from the same start position.
/// When both find a match ending at the same position `j`, they rendezvous
/// and resume the main parse at `j`.
class ConjunctionTracker {
  ConjunctionTracker({
    required this.leftSymbol,
    required this.rightSymbol,
    required this.startPosition,
  });
  final PatternSymbol leftSymbol;
  final PatternSymbol rightSymbol;
  final int startPosition;

  final Map<int, List<GlushList<Mark>>> leftCompletions = {};
  final Map<int, List<GlushList<Mark>>> rightCompletions = {};
  int activeFrames = 0;

  final List<(ParseNodeKey? source, Context, State)> waiters = [];

  void addPendingFrame() {
    activeFrames++;
  }

  void removePendingFrame() {
    assert(activeFrames > 0, "ConjunctionTracker underflow");
    activeFrames--;
  }

  bool get isExhausted => activeFrames == 0;
}

/// Tracks one negation sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same negation from multiple branches, so the
/// tracker counts how many negation-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the negation as matched
/// or exhausted, and then wake any parked continuations.
class NegationTracker {
  NegationTracker(this.symbol, this.startPosition);
  final PatternSymbol symbol;
  final int startPosition;
  int activeFrames = 0;

  /// Set of end positions j that the sub-parse A matched.
  final Set<int> matchedPositions = <int>{};

  /// Every input position that the sub-parse had live frames at.
  /// Used to enumerate candidate spans for unconstrained negation.
  final Set<int> visitedPositions = <int>{};

  /// Map of end positions j to waiters that should resume if A does NOT match j.
  final Map<int, List<(Context, State)>> waiters = {};

  /// Waiters with no specific target j — fire at every visited position
  /// that A did NOT match.
  final List<(Context, State)> unconstrainedWaiters = [];

  /// Add a waiter for a specific end position.
  void addWaiter(int endPosition, (Context, State) waiter) {
    (waiters[endPosition] ??= []).add(waiter);
  }

  /// Record that the sub-parse matched [endPosition] and cancel any parked waiters there.
  void markMatchedPosition(int endPosition) {
    matchedPositions.add(endPosition);
    waiters.remove(endPosition);
  }

  /// Whether a waiter for [endPosition] is still parked.
  bool hasWaiterAt(int endPosition) => waiters.containsKey(endPosition);

  /// Mark one negation-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one negation-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      "NegationTracker underflow: removePendingFrame() called with no pending frames.",
    );
    activeFrames--;
  }

  /// True when the negation sub-parse is fully exhausted.
  bool get isExhausted => activeFrames == 0;
}
