import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/action_key.dart";
import "package:glush/src/parser/common/caller_cache_key.dart";
import "package:glush/src/parser/common/caller_key.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";

/// Stateful cursor for manual state-machine parsing.
///
/// This standardizes the low-level token processing API by carrying the frame
/// list, current position, and parser flags between calls.
final class ParseState {
  ParseState(
    this.parser, {
    required List<Frame> initialFrames,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.tracer = const NullTracer(),
  }) : // Initialize active frames with the starting set provided by the parser.
       frames = initialFrames,
       // Index rules by name for faster lookup during guard evaluation.
       rulesByName = {for (var rule in parser.grammar.rules) rule.name.symbol: rule} {
    tracer.onStart(parser.stateMachine);
  }

  /// The parser definition being executed.
  final GlushParser parser;

  /// True when multiple derivations must be preserved instead of deduped.
  final bool isSupportingAmbiguity;

  /// True when consumed exact tokens should be emitted as `StringMark`s.
  final bool captureTokensAsMarks;

  /// Optional tracer for diagnostics.
  final ParseTracer tracer;

  /// Token history indexed by input position so lagging frames can catch up.
  final List<int> historyByPosition = [];

  /// Live predicate sub-parses keyed by `(pattern, startPosition)`.
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};

  /// Shared conjunction sub-parses keyed by `(left, right, startPosition)`.
  final Map<ConjunctionKey, ConjunctionTracker> conjunctionTrackers = {};

  final Map<NegationKey, NegationTracker> negationTrackers = {};

  /// Memoized call sites keyed by rule, precedence constraints, and call arguments.
  /// Keys can be `int` (packed) or [ComplexCallerCacheKey].
  final Map<CallerCacheKey, Caller> callers = {};

  /// Rules indexed by source name for guard expression evaluation.
  final Map<String, Rule> rulesByName;

  /// Shared label-capture cache keyed by persistent mark forests and capture name.
  final Map<(GlushList<Mark>, String), CaptureValue?> labelCaptureCache = {};

  /// Current zero-based input position for the next token to process.
  int position = 0;

  /// Active frames carried forward to the next `processToken` call.
  List<Frame> frames;

  /// Counter for assigning unique IDs to Caller nodes created during this parse.
  int callerCounter = 1;

  /// Last step produced by the parser, used for final accept/match results.
  Step? _lastStep;

  /// Process one input code unit and advance the parser by one position.
  /// advance the parser.
  Step processToken(int unit) {
    tracer.onStepStart(position, unit, frames);

    // Measure performance of the token processing step.
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
    // Advance the active frame set to the next parser position.
    frames = step.nextFrames;
    position++;
    _lastStep = step;
    return step;
  }

  /// Finalize the parse at end-of-input.
  Step finish() {
    tracer.onStepStart(position, null, frames);

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
    tracer.finalize();
    return step;
  }

  /// The most recent step returned by [processToken] or [finish].
  Step? get lastStep => _lastStep;

  StateMachine get stateMachine => parser.stateMachine;

  GrammarInterface get grammar => parser.grammar;

  /// Whether the most recent step accepted the full input.
  bool get accept => _lastStep?.accept ?? false;

  /// Marks from the most recent step.
  List<Mark> get marks => _lastStep?.marks ?? const [];
}
