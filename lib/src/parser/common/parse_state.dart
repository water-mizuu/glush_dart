import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
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

  final GlushParser parser;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final ParseTracer? tracer;
  final List<int> historyByPosition = [];
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};
  final Map<ConjunctionKey, ConjunctionTracker> conjunctionTrackers = {};
  final Map<NegationKey, NegationTracker> negationTrackers = {};

  /// Memoized call sites keyed by rule, precedence constraints, and call arguments.
  final Map<int, Caller> callersInt = {};
  final Map<ComplexCallerCacheKey, Caller> callersComplex = {};

  final Map<RuleName, Rule> rulesByName;
  final Map<int, Rule> rulesById;
  final Map<(GlushList<Mark>, String), CaptureValue?> labelCaptureCache = {};

  int position = 0;
  List<Frame> frames;
  int callerCounter = 1;
  Step? _lastStep;

  /// Process one input code unit and advance the parser by one position.
  Step processToken(int unit) {
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
    position++;
    _lastStep = step;
    return step;
  }

  /// Finalize the parse at end-of-input.
  Step finish() {
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

  LazyGlushList<Mark>? get forest => _lastStep
      ?.acceptedContexts
      .values //
      .fold<LazyGlushList<Mark>>(const LazyGlushList.empty(), LazyGlushList.branched);

  Step? get lastStep => _lastStep;
  StateMachine get stateMachine => parser.stateMachine;
  GrammarInterface get grammar => parser.grammar;
  bool get accept => _lastStep?.accept ?? false;
}
