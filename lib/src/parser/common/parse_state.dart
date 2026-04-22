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
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A stateful object that tracks the progress of a single parsing session.
///
/// [ParseState] maintains all the transient state required to drive the
/// [StateMachine] over an input stream, including:
/// - The current set of active [frames].
/// - The input [historyByPosition] (for lookahead recovery).
/// - Memoized callers for the Graph-Shared Stack.
/// - Sub-parse [trackers] for lookahead predicates and conjunctions.
final class ParseState {
  /// Creates a [ParseState] for a specific [parser].
  ParseState(
    this.parser, {
    required List<Frame> initialFrames,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.tracer,
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

  /// A history of processed tokens, used to resolve lookahead predicates.
  final List<int> historyByPosition = [];

  /// Active trackers for lookahead predicates and conjunctions.
  final Map<SubparseKey, SubparseTracker> trackers = {};

  /// Pending frame counts for active sub-parses, keyed by tracker key.
  final Map<SubparseKey, int> _trackerFrameCounts = {};

  /// Memoized boolean outcomes for resolved predicate lookaheads.
  final Map<PredicateKey, bool> predicateOutcomes = {};

  /// Memoized call sites for rules with complex (object-key) identities.
  final Map<CallerCacheKey, Caller> callersComplex = {};

  /// A fast lookup map for rules by their unique names.
  final Map<RuleName, Rule> rulesByName;

  /// A fast lookup map for rules by their numeric symbol IDs.
  final Map<int, Rule> rulesById;

  /// The current index in the input stream (zero-based).
  int position = 0;

  /// Internal counter used to assign unique IDs to GSS [Caller] nodes.
  int callerCounter = 1;

  Step? _lastStep;

  /// Advances the parser by processing a single [unit] (token).
  ///
  /// This method updates the [frames] for the next position and logs
  /// diagnostic information if a [tracer] is present.
  Step processToken(int unit) {
    historyByPosition.add(unit);
    tracer?.onStepStart(position, unit, frames);

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
    var deferredForNext = step.deferredFramesByPosition.remove(position + 1);
    if (deferredForNext != null) {
      frames.addAll(deferredForNext);
    }

    position++;
    _lastStep = step;
    return step;
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
  bool get hasPendingWork => frames.isNotEmpty;

  void _forEachActiveTrackerKey(Context context, void Function(SubparseKey key) action) {
    if (context.predicateStack.lastOrNull case var pk?) {
      action(PredicateKey(pk.pattern, pk.startPosition, isAnd: pk.isAnd, name: pk.name));
    }
    if (context.caller case ConjunctionCallerKey con) {
      action(ConjunctionKey(con.left, con.right, con.startPosition));
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
