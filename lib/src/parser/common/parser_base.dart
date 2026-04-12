import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// Base class for the Glush parser implementation.
///
/// Implements the core GLL-like parsing logic using the Glushkov state machine.
abstract class GlushParserBase implements GlushParser {
  GlushParserBase({required this.stateMachine, required this.captureTokensAsMarks});

  @override
  final StateMachine stateMachine;

  @override
  final bool captureTokensAsMarks;

  @override
  GrammarInterface get grammar => stateMachine.grammar;

  @override
  List<Frame> get initialFrames {
    var rootCaller = const RootCallerKey();
    var rootContext = Context(rootCaller);
    var frame = Frame(rootContext, const LazyGlushList.empty());
    frame.nextStates.add(stateMachine.startState);
    return [frame];
  }

  /// Create a new [ParseState] for this parser.
  ParseState createParseState({bool isSupportingAmbiguity = false, bool? captureTokensAsMarks}) {
    return ParseState(
      this,
      initialFrames: initialFrames,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
    );
  }

  /// Internal processing of a token at a specific position.
  @override
  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
  }) {
    if (token != null && parseState.historyByPosition.length == currentPosition) {
      parseState.historyByPosition.add(token);
    }

    var workQueue = _PositionWorkQueue();
    _enqueueFramesForPosition(parseState, workQueue, frames);

    // Re-use a single Step object for this entire position.
    var step = Step(
      parseState,
      token,
      currentPosition,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
    );

    bool positionExhausted = false;
    while (!positionExhausted) {
      // Tier A: Literal sub-parse exhaustion (everything at this position).
      while (workQueue.hasWork(currentPosition) ||
          (parseState.futureWork[currentPosition]?.isNotEmpty ?? false)) {
        if (!workQueue.hasWork(currentPosition)) {
          var frames = parseState.futureWork.remove(currentPosition)!;
          print("Draining futureWork for $currentPosition: ${frames.length} frames");
          _enqueueFramesForPosition(parseState, workQueue, frames);
        }
        var positionFrames = workQueue.dequeueAll(currentPosition);
        for (var frame in positionFrames) {
          parseState.decrementTrackers(frame.context, "process position queue");
          step.processFrameEnqueue(frame);
        }
        // Exhaust same-step closure.
        step.processFrameFinalize();
      }

      // Tier B: Negation complementation (persistent negations).
      // Triggered only after all literals for this position are exhausted.
      if (_updateNegationTrackers(parseState, workQueue, currentPosition)) {
        // If we found complement matches, loop back to drain them in Tier A.
        continue;
      }

      positionExhausted = true;
    }

    // Step C: Check for negations that completed their entire span to wake parked waiters.
    _checkExhaustedNegations(parseState, workQueue, currentPosition);

    // Finalize transfers token-consuming frames from currentPosition to currentPosition + 1.
    step.finalize();
    for (var nextFrame in step.nextFrames) {
      parseState.decrementTrackers(nextFrame.context, "transfer next");
      parseState.enqueueAt(nextFrame.context.position, nextFrame);
    }

    return step;
  }

  /// Update all active negation trackers for a given input position.
  /// Returns true if any new matches were enqueued.
  bool _updateNegationTrackers(ParseState parseState, _PositionWorkQueue workQueue, int position) {
    bool enqueuedAny = false;
    for (var tracker in parseState.negationTrackers.values) {
      if (position >= tracker.startPosition) {
        // Persistent negations yield a match at every new position that wasn't matched literally.
        if (tracker.visitedPositions.contains(position) &&
            !tracker.matchedPositions.contains(position) &&
            !tracker.persistedPositions.contains(position)) {
          tracker.persistedPositions.add(position);
          for (var (context, nextState, marks) in tracker.persistentWaiters) {
            var finalMarks = marks;
            if (parseState.captureTokensAsMarks) {
              for (int k = tracker.startPosition; k < position; k++) {
                var charCode = parseState.historyByPosition[k];
                finalMarks = finalMarks.add(StringMarkVal(String.fromCharCode(charCode), k));
              }
            }
            _enqueueAt(
              workQueue,
              position,
              nextState,
              context.advancePosition(position),
              finalMarks,
              parseState: parseState,
            );
            enqueuedAny = true;
          }
        }
      }
    }
    return enqueuedAny;
  }

  void _enqueueFramesForPosition(
    ParseState parseState,
    _PositionWorkQueue queue,
    List<Frame> frames,
  ) {
    for (var frame in frames) {
      parseState.incrementTrackers(frame.context, "enqueue frames");
      queue.addFrame(frame.context.position, frame);
    }
  }

  void _enqueueAt(
    _PositionWorkQueue workQueue,
    int position,
    State state,
    Context context,
    LazyGlushList<Mark> marks, {
    required ParseState parseState,
  }) {
    var frame = Frame(context, marks);
    frame.nextStates.add(state);
    parseState.incrementTrackers(context, "enqueue single");
    workQueue.addFrame(position, frame);
  }

  void _checkExhaustedPredicates(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int position,
  ) {
    var exhausted = parseState.predicateTrackers.entries.where((e) => e.value.isExhausted).toList();
    for (var entry in exhausted) {
      var key = entry.key;
      var tracker = entry.value;
      parseState.predicateTrackers.remove(key);

      if (!tracker.isAnd && !tracker.matched) {
        for (var (source, parentContext, nextState, parentMarks) in tracker.waiters) {
          _enqueueAt(
            workQueue,
            position,
            nextState,
            parentContext,
            parentMarks,
            parseState: parseState,
          );
        }
      }
    }
  }

  void _checkExhaustedNegations(ParseState parseState, _PositionWorkQueue workQueue, int position) {
    var keysToProcess = parseState.negationTrackers.entries
        .where((e) => e.value.isExhausted && !e.value.isSubparseFinished)
        .map((e) => e.key)
        .toList();

    for (var key in keysToProcess) {
      var tracker = parseState.negationTrackers[key]!;
      tracker.isSubparseFinished = true;

      for (var entry in tracker.waiters.entries) {
        var j = entry.key;
        if (!tracker.matchedPositions.contains(j)) {
          for (var (context, nextState, marks) in entry.value) {
            var finalMarks = marks;
            if (parseState.captureTokensAsMarks) {
              for (int k = tracker.startPosition; k < j; k++) {
                var charCode = parseState.historyByPosition[k];
                finalMarks = finalMarks.add(StringMarkVal(String.fromCharCode(charCode), k));
              }
            }
            _enqueueAt(
              workQueue,
              j,
              nextState,
              context.advancePosition(j),
              finalMarks,
              parseState: parseState,
            );
          }
        }
      }
      tracker.waiters.clear();
    }
  }
}

final class _PositionWorkQueue {
  final List<(int position, Frame frame)> _heap = [];

  bool get isEmpty => _heap.isEmpty;
  bool get isNotEmpty => _heap.isNotEmpty;

  int? get firstKeyOrNull => _heap.isEmpty ? null : _heap.first.$1;

  bool hasWork(int position) => _heap.isNotEmpty && _heap.first.$1 == position;

  List<Frame> dequeueAll(int position) {
    List<Frame> frames = [];
    while (_heap.isNotEmpty && _heap.first.$1 == position) {
      frames.add(_removeFirst());
    }
    return frames;
  }

  Frame _removeFirst() {
    var result = _heap[0].$2;
    var last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return result;
  }

  void addFrame(int position, Frame frame) {
    _heap.add((position, frame));
    _siftUp(_heap.length - 1);
  }

  void _siftUp(int index) {
    while (index > 0) {
      int parent = (index - 1) >> 1;
      if (_heap[parent].position <= _heap[index].position) {
        break;
      }
      var temp = _heap[parent];
      _heap[parent] = _heap[index];
      _heap[index] = temp;
      index = parent;
    }
  }

  void _siftDown(int index) {
    while (true) {
      int left = (index << 1) + 1;
      int right = (index << 1) + 2;
      int smallest = index;
      if (left < _heap.length && _heap[left].position < _heap[smallest].position) {
        smallest = left;
      }
      if (right < _heap.length && _heap[right].position < _heap[smallest].position) {
        smallest = right;
      }
      if (smallest == index) break;
      var temp = _heap[index];
      _heap[index] = _heap[smallest];
      _heap[smallest] = temp;
      index = smallest;
    }
  }
}

extension _RecPos on (int position, Frame frame) {
  int get position => this.$1;
}
