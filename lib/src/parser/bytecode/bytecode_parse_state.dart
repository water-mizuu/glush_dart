import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/bytecode/bytecode_frame.dart";
import "package:glush/src/parser/bytecode/bytecode_machine.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";

/// A version of [ParseState] optimized for the bytecode runtime.
class BytecodeParseState {
  BytecodeParseState(
    this.parser, {
    required List<BytecodeFrame> initialFrames,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.tracer,
  }) : frames = initialFrames,
       rulesById = {for (var rule in parser.grammar.rules) rule.symbolId!: rule};

  final BCParser parser;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final ParseTracer? tracer;

  List<BytecodeFrame> frames;
  final List<int> historyByPosition = [];
  final Map<SubparseKey, SubparseTracker<int>> trackers = {};
  final Map<SubparseKey, int> _trackerFrameCounts = {};
  final Map<PredicateKey, bool> predicateOutcomes = {};
  final Map<CallerCacheKey, Caller> callers = {};
  final Map<int, Rule> rulesById;

  int position = 0;
  int callerCounter = 1;
  BytecodeMachine get machine => parser.machine;

  void incrementTrackers(Context context, String reason) {
    var callerKey = context.predicateStack.lastOrNull;
    if (callerKey != null) {
      var predicateKey = callerKey.key;
      var tracker = trackers[predicateKey];
      if (tracker != null) {
        _trackerFrameCounts[predicateKey] = (_trackerFrameCounts[predicateKey] ?? 0) + 1;
      }
    }
  }

  PredicateKey? decrementTracker(Context context, [String? reason]) {
    var callerKey = context.predicateStack.lastOrNull;
    if (callerKey == null) {
      return null;
    }
    var predicateKey = callerKey.key;
    var tracker = trackers[predicateKey];
    if (tracker != null) {
      var current = _trackerFrameCounts[predicateKey] ?? 0;
      var next = current - 1;
      _trackerFrameCounts[predicateKey] = next;
      if (tracker is PredicateTracker<int> && !tracker.matched && !tracker.exhausted && next == 0) {
        return predicateKey;
      }
    }
    return null;
  }

  void memoizePredicateOutcome(PredicateKey key, {required bool isMatched}) {
    predicateOutcomes[key] = isMatched;
  }

  int trackerPendingFrames(SubparseKey key) => _trackerFrameCounts[key] ?? 0;

  void removeTracker(SubparseKey key) {
    trackers.remove(key);
    _trackerFrameCounts.remove(key);
  }
}
