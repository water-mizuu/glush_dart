import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/bytecode/bytecode_frame.dart";
import "package:glush/src/parser/bytecode/bytecode_machine.dart";
import "package:glush/src/parser/bytecode/bytecode_parse_state.dart";
import "package:glush/src/parser/bytecode/bytecode_step.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_result.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A standalone, high-performance bytecode parser for Glush.
class BCParser implements RecognizerAndMarksParser {
  BCParser(this.grammar) {
    stateMachine = StateMachine(grammar);
    machine = stateMachine.toBytecodeMachine();
  }

  late final StateMachine stateMachine;
  late final BytecodeMachine machine;
  final GrammarInterface grammar;

  @override
  bool recognize(String input) {
    return parse(input) is ParseSuccess;
  }

  @override
  ParseOutcome parse(String input) {
    return _run(input, isAmbiguous: false);
  }

  @override
  ParseOutcome parseAmbiguous(
    String input, {
    bool captureTokensAsMarks = false,
    ParseTracer? tracer,
  }) {
    return _run(input, isAmbiguous: true, captureTokensAsMarks: captureTokensAsMarks);
  }

  ParseOutcome _run(String input, {required bool isAmbiguous, bool captureTokensAsMarks = false}) {
    var bytes = input.codeUnits;
    var initialFrames = List<BytecodeFrame>.generate(
      machine.initialStates.length,
      (i) => BytecodeFrame(Context(const RootCallerKey()), const LazyGlushList<Mark>.empty(), [i]),
    );

    var parseState = BytecodeParseState(
      this,
      initialFrames: initialFrames,
      isSupportingAmbiguity: isAmbiguous,
      captureTokensAsMarks: captureTokensAsMarks,
    );

    var nextFramesBuffer = <BytecodeFrame>[];
    var currentAccepted = <Context, LazyGlushList<Mark>>{};
    var exhaustedPredicates = <PredicateKey>[];

    // Position work queue buffers
    var stepsAtPosition = <int, BytecodeStep>{};

    for (var i = 0; i <= bytes.length; i++) {
      var byte = i < bytes.length ? bytes[i] : null;

      nextFramesBuffer.clear();
      currentAccepted.clear();

      if (byte != null) {
        if (parseState.historyByPosition.length <= i) {
          parseState.historyByPosition.add(byte);
        }
      }

      exhaustedPredicates.clear();
      while (true) {
        var (next, accepted) = _processToken(
          byte,
          parseState.position,
          parseState.frames,
          parseState,
          exhaustedPredicatesSink: exhaustedPredicates,
          stepsBuffer: stepsAtPosition,
        );
        nextFramesBuffer.addAll(next);
        var continueLoop = false;

        // Split accepted between root and predicates
        for (var entry in accepted.entries) {
          var context = entry.key;
          if (context.caller is RootCallerKey) {
            currentAccepted[context] = entry.value;
          } else if (context.caller is PredicateCallerKey) {
            _resolvePredicateTrue(
              parseState,
              context.caller as PredicateCallerKey,
              exhaustedPredicates,
            );
            continueLoop = true;
          }
        }

        parseState.frames.clear();

        if (exhaustedPredicates.isNotEmpty) {
          var resumedFrames = _resolvePredicatesFalse(parseState, exhaustedPredicates);
          if (resumedFrames.isNotEmpty) {
            parseState.frames.addAll(resumedFrames);
            continueLoop = true;
          }
          exhaustedPredicates.clear();
        }

        if (!continueLoop) {
          break;
        }
      }

      if (byte == null) {
        if (currentAccepted.isEmpty) {
          return ParseError(parseState.position);
        }
        var forest = currentAccepted.values.reduce((a, b) => LazyGlushList.branched(a, b));
        if (isAmbiguous) {
          return ParseAmbiguousSuccess(forest);
        }
        return ParseSuccess(forest.evaluate().iterate().toList());
      }

      if (nextFramesBuffer.isEmpty) {
        return ParseError(parseState.position);
      }

      // Swap buffers to avoid allocations
      var temp = parseState.frames;
      parseState.frames = nextFramesBuffer;
      nextFramesBuffer = temp;
      parseState.position++;
      stepsAtPosition.clear();
    }

    return ParseError(parseState.position);
  }

  void _resolvePredicateTrue(
    BytecodeParseState parseState,
    PredicateCallerKey callerKey,
    List<PredicateKey>? exhaustedPredicatesSink,
  ) {
    var predicateKey = callerKey.key;
    var tracker = parseState.trackers[predicateKey] as PredicateTracker<int>?;
    if (tracker == null || tracker.matched) {
      return;
    }

    tracker.matched = true;
    parseState.memoizePredicateOutcome(predicateKey, isMatched: true);

    for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
      var exhausted = parseState.decrementTracker(parentContext, "resolveTrue");
      if (exhausted != null) {
        exhaustedPredicatesSink?.add(exhausted);
      }
      if (tracker.isAnd) {
        var frame = BytecodeFrame(parentContext, parentMarks, [nextState]);
        parseState.incrementTrackers(parentContext, "resumedTrueFrame");
        parseState.frames.add(frame);
      }
    }
    tracker.waiters.clear();
    parseState.removeTracker(predicateKey);
  }

  List<BytecodeFrame> _resolvePredicatesFalse(
    BytecodeParseState parseState,
    List<PredicateKey> exhausted,
  ) {
    var resumed = <BytecodeFrame>[];
    // Use a working list so cascading exhaustions (inner predicate's failure
    // decrementing an outer predicate's count to 0) are fully resolved.
    var pending = exhausted.toList();
    var i = 0;
    while (i < pending.length) {
      var key = pending[i++];
      var tracker = parseState.trackers[key] as PredicateTracker<int>?;
      if (tracker == null ||
          tracker.matched ||
          tracker.exhausted ||
          parseState.trackerPendingFrames(key) != 0) {
        continue;
      }

      tracker.exhausted = true;
      parseState.memoizePredicateOutcome(key, isMatched: false);

      for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
        var cascaded = parseState.decrementTracker(parentContext, "resolveFalse");
        if (cascaded != null) {
          pending.add(cascaded); // ← cascade: outer predicate may now be exhausted
        }
        if (!tracker.isAnd) {
          var frame = BytecodeFrame(parentContext, parentMarks, [nextState]);
          // Increment immediately (like SM's _enqueueFrameForPosition) so that if
          // the cascade just above decremented an outer predicate's count to 0,
          // this +1 restores it before the cascade processes that outer key.
          parseState.incrementTrackers(parentContext, "resumeNotPredicate");
          resumed.add(frame);
        }
      }
      tracker.waiters.clear();
      parseState.removeTracker(key);
    }

    return resumed;
  }

  (List<BytecodeFrame> nextFrames, Map<Context, LazyGlushList<Mark>> accepted) _processToken(
    int? token,
    int currentPosition,
    List<BytecodeFrame> frames,
    BytecodeParseState parseState, {
    List<PredicateKey>? exhaustedPredicatesSink,
    Map<int, BytecodeStep>? stepsBuffer,
  }) {
    var workQueue = _BytecodePositionWorkQueue();
    var stepsAtPosition = stepsBuffer ?? <int, BytecodeStep>{};
    var allNextFrames = <BytecodeFrame>[];
    var allAccepted = <Context, LazyGlushList<Mark>>{};

    for (var frame in frames) {
      workQueue.addFrame(frame.context.position, frame);
    }

    while (workQueue.isNotEmpty) {
      var pos = workQueue.firstPriority!;

      var items = workQueue.removeFirst();
      var step = stepsAtPosition[pos] ??= BytecodeStep(
        machine,
        parseState,
        _getTokenAt(pos, token, currentPosition, parseState),
        pos,
        isSupportingAmbiguity: parseState.isSupportingAmbiguity,
        captureTokensAsMarks: parseState.captureTokensAsMarks,
      )..exhaustedPredicatesSink = exhaustedPredicatesSink;

      for (var item in items) {
        var exhausted = parseState.decrementTracker(item.context, "preDequeue");
        if (exhausted != null) {
          exhaustedPredicatesSink?.add(exhausted);
        }
        step.processFrameEnqueue(item);
      }
      step.processFrameFinalize();
      step.finalize();

      for (var f in step.nextFrames) {
        if (token != null && f.context.position > currentPosition) {
          allNextFrames.add(f);
        } else {
          workQueue.addFrame(f.context.position, f);
        }
      }
      for (var f in step.requeued) {
        if (token != null && f.context.position > currentPosition) {
          allNextFrames.add(f);
        } else {
          workQueue.addFrame(f.context.position, f);
        }
      }

      if (pos == currentPosition) {
        allAccepted.addAll(step.acceptedContexts);
      }

      step.nextFrames.clear();
      step.requeued.clear();
    }

    return (allNextFrames, allAccepted);
  }

  @pragma("vm:prefer-inline")
  int? _getTokenAt(
    int pos,
    int? currentToken,
    int currentPosition,
    BytecodeParseState state,
  ) {
    if (pos == currentPosition) {
      return currentToken;
    }
    var history = state.historyByPosition;
    if (pos < 0 || pos >= history.length) {
      return null;
    }
    return history[pos];
  }
}

class _BytecodePositionWorkQueue {
  final Map<int, List<BytecodeFrame>> _map = {};
  int _minPos = 2147483647;

  bool get isNotEmpty => _map.isNotEmpty;

  int? get firstPriority => _map.isEmpty ? null : _minPos;

  void addFrame(int pos, BytecodeFrame frame) {
    _map.putIfAbsent(pos, () => []).add(frame);
    if (pos < _minPos) {
      _minPos = pos;
    }
  }

  List<BytecodeFrame> removeFirst() {
    var list = _map.remove(_minPos)!;
    if (_map.isEmpty) {
      _minPos = 2147483647;
    } else {
      var nextMin = 2147483647;
      for (var pos in _map.keys) {
        if (pos < nextMin) {
          nextMin = pos;
        }
      }
      _minPos = nextMin;
    }
    return list;
  }
}
