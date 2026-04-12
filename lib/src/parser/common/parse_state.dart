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

/// Stateful cursor for manual state-machine parsing.
final class ParseState {
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

  List<Frame> frames;
  final GlushParser parser;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final ParseTracer? tracer;
  final List<int> historyByPosition = [];
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};
  final Map<ConjunctionKey, ConjunctionTracker> conjunctionTrackers = {};

  /// Memoized call sites keyed by rule, precedence constraints, and call arguments.
  final Map<int, Caller> callersInt = {};
  final Map<ComplexCallerCacheKey, Caller> callersComplex = {};

  final Map<RuleName, Rule> rulesByName;
  final Map<int, Rule> rulesById;

  int position = 0;
  int callerCounter = 1;
  Step? _lastStep;

  /// Process one input code unit and advance the parser by one position.
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

    // Combine next-position frames with any deferred frames for the next position
    frames = step.nextFrames;
    var deferredForNext = step.deferredFramesByPosition.remove(position + 1);
    if (deferredForNext != null) {
      frames.addAll(deferredForNext);
    }

    // Track active predicates/conjunctions
    GlushProfiler.increment("parser.predicates.active", predicateTrackers.length);
    GlushProfiler.increment("parser.conjunctions.active", conjunctionTrackers.length);
    GlushProfiler.increment("parser.callers.total", callersInt.length + callersComplex.length);

    position++;
    _lastStep = step;
    return step;
  }

  /// Finalize the parse at end-of-input.
  Step finish() {
    GlushProfiler.increment("parser.steps.finish");
    GlushProfiler.increment("parser.frames.finish", frames.length);
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

    // Record final cache statistics
    GlushProfiler.increment("parser.cache.predicates_final", predicateTrackers.length);
    GlushProfiler.increment("parser.cache.conjunctions_final", conjunctionTrackers.length);

    _lastStep = step;
    tracer?.finalize();
    return step;
  }

  LazyGlushList<Mark>? get forest => _lastStep
      ?.acceptedContexts
      .values //
      .fold<LazyGlushList<Mark>>(const LazyGlushList.empty(), LazyGlushList.branched);

  Step? get lastStep => _lastStep;
  StateMachine get stateMachine => parser.stateMachine;
  GrammarInterface get grammar => parser.grammar;
  bool get accept => _lastStep?.accept ?? false;
  bool get hasPendingWork => frames.isNotEmpty;

  void incrementTrackers(Context context, String reason) {
    if (context.predicateStack.lastOrNull case var pk?) {
      var pKey = PredicateKey(pk.pattern, pk.startPosition, isAnd: pk.isAnd, name: pk.name);
      var tracker = predicateTrackers[pKey];
      if (tracker != null) {
        tracker.addPendingFrame();
        GlushProfiler.increment("parser.predicate_frames.added");
        tracer?.onTrackerUpdate("Predicate", tracker.toString(), tracker.activeFrames, reason);
      }
    }

    if (context.caller case ConjunctionCallerKey con) {
      var key = ConjunctionKey(con.left, con.right, con.startPosition);
      var tracker = conjunctionTrackers[key];
      if (tracker != null) {
        tracker.addPendingFrame();
        GlushProfiler.increment("parser.conjunction_frames.added");
        tracer?.onTrackerUpdate("Conjunction", tracker.toString(), tracker.activeFrames, reason);
      }
    }
  }

  void decrementTrackers(Context context, [String? reason]) {
    if (context.predicateStack.lastOrNull case var pk?) {
      var key = PredicateKey(pk.pattern, pk.startPosition, isAnd: pk.isAnd, name: pk.name);
      var tracker = predicateTrackers[key];
      if (tracker != null) {
        tracker.removePendingFrame();
        GlushProfiler.increment("parser.predicate_frames.removed");
        if (reason != null) {
          tracer?.onTrackerUpdate("Predicate", tracker.toString(), tracker.activeFrames, reason);
        }
      }
    }

    if (context.caller case ConjunctionCallerKey caller) {
      var key = ConjunctionKey(caller.left, caller.right, caller.startPosition);
      var tracker = conjunctionTrackers[key];
      // Conjunctions might have 0 active frames if they finished early but the frame is still being processed
      if (tracker != null && tracker.activeFrames > 0) {
        tracker.removePendingFrame();
        GlushProfiler.increment("parser.conjunction_frames.removed");
        if (reason != null) {
          tracer?.onTrackerUpdate("Conjunction", tracker.toString(), tracker.activeFrames, reason);
        }
      }
    }
  }
}
