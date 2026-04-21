import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/key/parse_node_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A parked continuation representing a parse path waiting for a sub-parse to complete.
///
/// A [Waiter] captures all the state necessary to resume parsing once a
/// lookahead predicate or conjunction condition is satisfied. It includes:
/// - [ParseNodeKey?]: The source node for forest construction.
/// - [Context]: The parsing environment (caller, captures, etc.).
/// - [State]: The state to transition to upon resumption.
/// - [LazyGlushList<Mark>]: The accumulated mark stream.
typedef Waiter = (ParseNodeKey?, Context, State, LazyGlushList<Mark>);

/// Base class for coordinating asynchronous or non-linear sub-parses.
///
/// Trackers are used to manage derivation paths that diverge from the main
/// linear token stream, such as lookahead predicates or intersecting
/// conjunctions. They keep track of how many active frames belong to the
/// sub-parse and manage a list of [waiters] that should be resumed when certain
/// conditions are met.
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

/// Coordinates the execution of a lookahead predicate (&pattern or !pattern).
///
/// A [PredicateTracker] ensures that a lookahead sub-parse is only initiated
/// once for a given (pattern, position) pair. It tracks the progress of all
/// branches within that sub-parse using [activeFrames].
///
/// If any branch completes successfully, the predicate is marked as [matched].
/// When all branches are finished, the predicate is marked as [exhausted].
/// Parked continuations ([waiters]) are resumed based on whether the predicate
/// was an "AND" (resume on match) or a "NOT" (resume on exhaustion without match).
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

/// Coordinates the execution of an intersection rule (A & B).
///
/// In a conjunction, two independent sub-parses (left and right) are started
/// from the same initial position. The conjunction matches only if both sides
/// complete at the exact same end position.
///
/// The tracker stores completions for both sides in [leftCompletions] and
/// [rightCompletions], keyed by their end position. Whenever a new completion
/// is recorded, it checks if the other side has already completed at that same
/// position, and if so, it performs a rendezvous to resume any [waiters].
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
