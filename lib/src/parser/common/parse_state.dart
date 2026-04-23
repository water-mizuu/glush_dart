import "dart:collection";

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/incremental/finger_tree.dart";
import "package:glush/src/parser/incremental/interval_tree.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A snapshot of the parser state at a specific input position.
class ParseCheckpoint implements Shiftable<ParseCheckpoint> {
  ParseCheckpoint(this.position, this.frames, Map<int, List<Frame>> waitlist)
    : globalWaitlist = waitlist;
  final int position;
  final List<Frame> frames;
  final Map<int, List<Frame>> globalWaitlist;

  @override
  ParseCheckpoint shifted(int delta) {
    return ParseCheckpoint(
      position + delta,
      frames.map((f) => f.shifted(delta, 0)).toList(),
      globalWaitlist.map((k, v) => MapEntry(k + delta, v.map((f) => f.shifted(delta, 0)).toList())),
    );
  }
}

/// A stateful object that tracks the progress of a single parsing session.
///
/// [ParseState] maintains all the transient state required to drive the
/// [StateMachine] over an input stream, including:
/// - The current set of active [frames].
/// - Memoized callers for the Graph-Shared Stack.
/// - Sub-parse [trackers] for lookahead predicates.
final class ParseState {
  /// Creates a [ParseState] for a specific [parser].
  ParseState(
    this.parser, {
    required List<Frame> initialFrames,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.tracer,
    this.previousIntervalIndex,
    this.previousCheckpointIndex,
  }) : frames = initialFrames,
       rulesByName = {
         for (var rule in parser.grammar.rules) rule.name!: rule,
         for (var rule in parser.stateMachine.allRules.values) rule.name!: rule,
       },
       rulesById = {
         for (var rule in parser.grammar.rules) rule.symbolId!: rule,
         for (var rule in parser.stateMachine.allRules.values) rule.symbolId!: rule,
       } {
    tracer?.onStart(parser.stateMachine);
  }

  /// The active parser frames at the current input position.
  List<Frame> frames;

  /// The parser engine driving this state.
  final GlushParser parser;

  /// Whether this parse session allows and tracks ambiguous derivation paths.
  final bool isSupportingAmbiguity;

  /// Whether raw input tokens should be added to the semantic mark stream.
  final bool captureTokensAsMarks;

  /// Optional tracer for debugging and profiling the parse step-by-step.
  final ParseTracer? tracer;

  /// The global interval tree caching previous successful parse outcomes.
  final IntervalTree<CachedRuleResult> intervalIndex = IntervalTree<CachedRuleResult>();

  /// The interval index from the previous parse session, used for Papa Carlo subtree reuse.
  IntervalTree<CachedRuleResult>? previousIntervalIndex;

  /// The collection of checkpoints for fast resumption during incremental parsing.
  final IntervalTree<ParseCheckpoint> checkpointIndex = IntervalTree<ParseCheckpoint>();

  /// The checkpoint index from the previous parse session.
  IntervalTree<ParseCheckpoint>? previousCheckpointIndex;

  /// The finger tree managing the character sequence and positions.
  FingerTree positionManager = const FingerTree.empty();

  /// Active trackers for lookahead predicates.
  final Map<SubparseKey, SubparseTracker> trackers = {};

  /// Pending frame counts for active sub-parses, keyed by tracker key.
  final Map<SubparseKey, int> _trackerFrameCounts = {};

  /// Memoized boolean outcomes for resolved predicate lookaheads.
  final Map<PredicateKey, bool> predicateOutcomes = {};

  /// Memoized call sites for rules with complex (object-key) identities.
  final Map<CallerCacheKey, Caller> callersComplex = {};

  /// A global waitlist for frames that have been fast-forwarded to a future position.
  final SplayTreeMap<int, List<Frame>> globalWaitlist = SplayTreeMap<int, List<Frame>>();

  /// A fast lookup map for rules by their unique names.
  final Map<RuleName, Rule> rulesByName;

  /// A fast lookup map for rules by their numeric symbol IDs.
  final Map<int, Rule> rulesById;

  /// The current index in the input stream (zero-based).
  int position = 0;

  /// Internal counter used to assign unique IDs to GSS [Caller] nodes.
  int callerCounter = 1;

  /// The collection of checkpoints for fast resumption during incremental parsing.
  // final SplayTreeMap<int, ParseCheckpoint> checkpoints = SplayTreeMap<int, ParseCheckpoint>();

  Step? _lastStep;

  /// Advances the parser by processing the next token from the position manager.
  ///
  /// This method updates the [frames] for the next position and logs
  /// diagnostic information if a [tracer] is present.
  Step processNextToken() {
    int? unit = positionManager.charCodeAt(position);
    tracer?.onStepStart(position, unit, frames);

    // Record a checkpoint at regular intervals for fast resumption.
    if (position % 100 == 0) {
      checkpointIndex.insert(
        position,
        position + 1,
        ParseCheckpoint(position, frames, globalWaitlist),
      );
    }

    var step = GlushProfiler.measure("parser.process_token", () {
      return parser.processToken(
        unit,
        position,
        frames,
        parseState: this,
        isSupportingAmbiguity: isSupportingAmbiguity,
        captureTokensAsMarks: captureTokensAsMarks,
      );
    });
    GlushProfiler.increment("parser.process_token.calls");

    frames = step.nextFrames;

    // Merge newly deferred frames into the global waitlist.
    step.deferredFramesByPosition.forEach((pos, defFrames) {
      globalWaitlist.putIfAbsent(pos, () => []).addAll(defFrames);
    });

    // Merge requeued frames (e.g. from predicate resolutions or return actions)
    for (var defFrame in step.requeued) {
      globalWaitlist.putIfAbsent(defFrame.context.position, () => []).add(defFrame);
    }

    // Advance to the next position with work.
    position++;

    // If no work at current position, jump to next work in global waitlist.
    if (frames.isEmpty && globalWaitlist.isNotEmpty) {
      var nextPos = globalWaitlist.firstKey()!;
      if (nextPos > position) {
        position = nextPos;
      }
    }

    // Pull waiting frames for the new position into the active set.
    var deferredForNow = globalWaitlist.remove(position);
    if (deferredForNow != null) {
      frames.addAll(deferredForNow);
    }

    _lastStep = step;
    return step;
  }

  /// Applies a character-level edit and returns a new [ParseState] for incremental re-parsing.
  ///
  /// This operation is O(log N) for position management and interval shifting.
  ParseState applyEdit(int start, int end, String replacement) {
    var delta = replacement.length - (end - start);

    // 1. Update the position manager (Rope) in O(log N)
    var newPositionManager = positionManager.replaceRange(start, end, replacement);

    // 2. Clone the current interval index and apply the edit shift/invalidation
    var newPreviousIndex = intervalIndex.copy();
    newPreviousIndex.applyEdit(start, end, delta);

    // 3. Find nearest checkpoint before the edit from the existing index.
    // Checkpoints at/before the edit don't need shifting.
    var checkpoint = _findLastCheckpointBefore(checkpointIndex, start);

    // 4. Mutate this parse state in place to avoid allocating/copying a full state.
    previousIntervalIndex = newPreviousIndex;
    previousCheckpointIndex = checkpointIndex;
    positionManager = newPositionManager;

    // Reset transient parse-session state.
    trackers.clear();
    _trackerFrameCounts.clear();
    predicateOutcomes.clear();
    callersComplex.clear();
    globalWaitlist.clear();
    _lastStep = null;

    // Reset caches for the new parse pass.
    intervalIndex.root = null;
    checkpointIndex.root = null;

    // 5. Resume from checkpoint or from the initial state.
    if (checkpoint != null) {
      position = checkpoint.position;
      frames = checkpoint.frames;
      globalWaitlist.addAll(checkpoint.globalWaitlist);
    } else {
      position = 0;
      frames = parser.initialFrames;
    }

    return this;
  }

  ParseCheckpoint? _findLastCheckpointBefore(IntervalTree<ParseCheckpoint> index, int pos) {
    return index.findLastStartingAtOrBefore(pos)?.result;
  }

  /// Completes the parse session after all input has been processed.
  ///
  /// This triggers final transitions (including end-of-input markers) and
  /// returns the final [Step] containing the acceptance status.
  Step finish() {
    GlushProfiler.increment("parser.steps.finish");
    tracer?.onStepStart(position, null, frames);

    var step = GlushProfiler.measure("parser.finish", () {
      return parser.processToken(
        null,
        position,
        frames,
        parseState: this,
        isSupportingAmbiguity: isSupportingAmbiguity,
        captureTokensAsMarks: captureTokensAsMarks,
      );
    });

    _lastStep = step;
    tracer?.finalize();
    return step;
  }

  /// Returns the complete parse forest as a lazy list of semantic marks.
  ///
  /// This merges all accepted derivation paths into a single branched list.
  LazyGlushList<Mark>? get forest => _lastStep?.acceptedContexts.values.fold<LazyGlushList<Mark>>(
    const LazyGlushList.empty(),
    LazyGlushList.branched,
  );

  /// Returns the results of the most recent [processToken] or [finish] call.
  Step? get lastStep => _lastStep;

  /// Returns the underlying state machine.
  StateMachine get stateMachine => parser.stateMachine;

  /// Returns the grammar being parsed.
  GrammarInterface get grammar => parser.grammar;

  /// Returns true if the input has been fully accepted.
  bool get accept => _lastStep?.accept ?? false;

  /// Returns true if there are still active frames to be processed.
  bool get hasPendingWork => frames.isNotEmpty || globalWaitlist.isNotEmpty;

  void _forEachActiveTrackerKey(Context context, void Function(SubparseKey key) action) {
    if (context.predicateStack.lastOrNull case var pk?) {
      action(PredicateKey(pk.pattern, pk.startPosition, isAnd: pk.isAnd, name: pk.name));
    }
  }

  /// Increments the pending frame count for all active trackers in [context].
  void incrementTrackers(Context context, String reason) {
    _forEachActiveTrackerKey(context, (key) {
      var tracker = trackers[key];
      if (tracker != null) {
        var next = (_trackerFrameCounts[key] ?? 0) + 1;
        _trackerFrameCounts[key] = next;
        _traceTrackerUpdate(tracker, reason, pendingFrames: next);
      }
    });
  }

  /// Decrements the pending frame count for all active trackers in [context].
  ///
  /// Returns predicate keys that are now exhaustible (no pending frames and no match).
  List<PredicateKey> decrementTrackers(Context context, [String? reason]) {
    var exhaustedPredicates = <PredicateKey>[];

    _forEachActiveTrackerKey(context, (key) {
      var tracker = trackers[key];
      if (tracker != null) {
        var current = _trackerFrameCounts[key] ?? 0;
        assert(
          current > 0,
          "${tracker.runtimeType} underflow: decrementTrackers() called with no pending frames for $key.",
        );

        var next = current - 1;
        _trackerFrameCounts[key] = next;
        if (key is PredicateKey &&
            tracker is PredicateTracker &&
            !tracker.matched &&
            !tracker.exhausted &&
            next == 0) {
          exhaustedPredicates.add(key);
        }

        if (reason != null) {
          _traceTrackerUpdate(tracker, reason, pendingFrames: next);
        }
      }
    });

    return exhaustedPredicates;
  }

  void _traceTrackerUpdate(SubparseTracker tracker, String reason, {required int pendingFrames}) {
    tracer?.onTrackerUpdate(
      tracker.runtimeType.toString(),
      tracker.toString(),
      pendingFrames,
      reason,
    );
  }

  int trackerPendingFrames(SubparseKey key) => _trackerFrameCounts[key] ?? 0;

  bool canResolvePredicateFalse(PredicateKey key, PredicateTracker tracker) {
    return !tracker.matched && !tracker.exhausted && trackerPendingFrames(key) == 0;
  }

  void removeTracker(SubparseKey key) {
    trackers.remove(key);
    _trackerFrameCounts.remove(key);
  }

  /// Memoizes the outcome of a resolved predicate.
  void memoizePredicateOutcome(PredicateKey key, {required bool isMatched}) {
    predicateOutcomes[key] = isMatched;
  }

  /// Returns a memoized predicate outcome, if one exists.
  bool? getMemoizedPredicateOutcome(PredicateKey key) => predicateOutcomes[key];
}

/// Represents a successfully parsed grammar rule, cached for incremental reuse.
class CachedRuleResult implements Shiftable<CachedRuleResult> {
  CachedRuleResult({
    required this.symbol,
    required this.nextPosition,
    required this.marks,
    this.precedenceLevel,
  });

  /// The symbol ID of the rule that was matched.
  final PatternSymbol symbol;

  /// Relative next-position payload represented as a pointer chain.
  final RelativePosition nextPosition;

  /// Compatibility getter for call sites still expecting a scalar delta.
  int get nextPositionDelta => nextPosition.offset;

  /// The precedence level of the rule match, used for disambiguation.
  final int? precedenceLevel;

  /// The marks produced by the rule internally.
  final LazyGlushList<Mark> marks;

  /// This payload is position-relative, so shifting is a no-op.
  @override
  CachedRuleResult shifted(int delta) {
    return this;
  }
}

/// A relative position represented as a chain of deltas to previous nodes.
///
/// Ordering can be derived recursively from the [previous] chain without
/// requiring absolute input offsets in cached reuse payloads.
class RelativePosition {
  /// Builds a relative position from a scalar distance using a linked chain.
  ///
  /// We encode the distance using power-of-two chunks, producing a compact
  /// ancestry chain while still supporting recursive ordering.
  factory RelativePosition.fromDistance(int distance) {
    if (distance < 0) {
      throw ArgumentError.value(distance, "distance", "must be >= 0");
    }
    if (distance == 0) {
      return zero;
    }

    var node = zero;
    var remaining = distance;
    while (remaining > 0) {
      var chunk = remaining & -remaining;
      node = RelativePosition._(node, chunk, depth: node.depth + 1, offset: node.offset + chunk);
      remaining -= chunk;
    }
    return node;
  }
  const RelativePosition._(this.previous, this.delta, {required this.depth, required this.offset});

  static const RelativePosition zero = RelativePosition._(null, 0, depth: 0, offset: 0);

  final RelativePosition? previous;
  final int delta;
  final int depth;

  /// Total offset from the root of this relative chain.
  final int offset;

  /// Compares two relative positions by recursively walking their ancestry.
  int compareByAncestry(RelativePosition other) {
    if (identical(this, other)) {
      return 0;
    }

    var a = this;
    var b = other;

    while (a.depth > b.depth) {
      a = a.previous!;
    }
    while (b.depth > a.depth) {
      b = b.previous!;
    }

    if (identical(a, b)) {
      return offset.compareTo(other.offset);
    }

    var aStack = <int>[];
    var bStack = <int>[];
    var aWalk = this;
    var bWalk = other;
    while (aWalk.previous != null) {
      aStack.add(aWalk.delta);
      aWalk = aWalk.previous!;
    }
    while (bWalk.previous != null) {
      bStack.add(bWalk.delta);
      bWalk = bWalk.previous!;
    }

    var shared = aStack.length < bStack.length ? aStack.length : bStack.length;
    for (var i = 1; i <= shared; i++) {
      var cmp = aStack[aStack.length - i].compareTo(bStack[bStack.length - i]);
      if (cmp != 0) {
        return cmp;
      }
    }

    return aStack.length.compareTo(bStack.length);
  }
}
