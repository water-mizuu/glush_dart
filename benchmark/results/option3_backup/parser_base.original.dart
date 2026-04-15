/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";

abstract base class GlushParserBase implements GlushParser {
  /// Initial frames for a fresh parse session.
  @override
  List<Frame> get initialFrames;

  /// Bucket frames by their [Context.position] into the global work queue.
  ///
  /// The parser may hold frames from multiple [Context.position]s simultaneously when calls
  /// and predicates create lagging continuations.
  void _enqueueFramesForPosition(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    List<Frame> frames,
  ) {
    for (var frame in frames) {
      parseState.incrementTrackers(frame.context, "enqueue list");
      workQueue.addFrame(frame.context.position, frame);
    }
  }

  /// Detect predicates that can now be resolved as exhausted (no active frames).
  ///
  /// Resolution is a cascading process: resolving one predicate can decrement
  /// parent predicate counters, potentially triggering further exhaustion.
  void _checkExhaustedPredicates(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
  ) {
    bool changed = true;
    while (changed) {
      changed = false;
      var toRemove = <SubparseKey>{};
      for (var entry in parseState.trackers.entries) {
        if (entry.value case PredicateTracker tracker) {
          if (!tracker.exhausted && tracker.canResolveFalse) {
            tracker.exhausted = true;
            for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
              parseState.decrementTrackers(parentContext, "childExhausted");

              if (!tracker.isAnd) {
                var targetPosition = parentContext.position;
                var nextFrame = Frame(parentContext, parentMarks)..nextStates.add(nextState);
                parseState.incrementTrackers(parentContext, "resumeNotPredicate");
                workQueue.addFrame(targetPosition, nextFrame);
              }
            }
            tracker.waiters.clear();
            toRemove.add(entry.key);
            changed = true;
          } else if (tracker.matched || tracker.exhausted) {
            toRemove.add(entry.key);
          }
        }
      }
      for (var key in toRemove) {
        parseState.trackers.remove(key);
      }
    }
  }

  /// Create a reusable manual parse cursor.
  ParseState createParseState({
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
    ParseTracer? tracer,
  }) {
    return ParseState(
      this,
      initialFrames: initialFrames,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
      tracer: tracer,
    );
  }

  /// Core single-token processing pipeline.
  ///
  /// High-level sequence:
  /// 1) Append token to history (for lagging [Context.position] replay)
  /// 2) Run a position-ordered work queue up to `currentPosition`
  /// 3) For each position: process frames, finalize token transitions
  /// 4) Cascadely run exhaustion checks for predicates and negations
  /// 5) Return the `Step` associated with the current requested position
  @override
  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
  }) {
    if (token != null && parseState.historyByPosition.length == currentPosition) {
      parseState.historyByPosition.add(token);
    }

    var stepsAtPosition = <int, Step>{};
    var workQueue = _PositionWorkQueue();

    _enqueueFramesForPosition(parseState, workQueue, frames);

    while (workQueue.isNotEmpty) {
      var position = workQueue.firstKeyOrNull!;
      // Work queue is sorted; once position exceeds current token, stop.
      // If token is null (EOF), we drain the entire queue to finalize results.
      if (token != null && position > currentPosition) {
        break;
      }

      var positionFrames = workQueue.removeFirst();

      if (stepsAtPosition[position] == null) {
        // Build one Step object per position lazily on first visit.
        stepsAtPosition[position] = Step(
          parseState,
          position == currentPosition
              ? token
              : position < parseState.historyByPosition.length
              ? parseState.historyByPosition[position]
              : null,
          position,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks,
        );
      }
      var currentStep = stepsAtPosition[position]!;

      // Process all frames' enqueueing first, then finalize work queue.
      for (var frame in positionFrames) {
        parseState.decrementTrackers(frame.context, "process position queue");
        currentStep.processFrameEnqueue(frame);
      }
      currentStep.processFrameFinalize();
      currentStep.finalize();

      var nextQueuedPosition = workQueue.firstKeyOrNull;
      if (nextQueuedPosition == null || nextQueuedPosition > currentPosition) {
        _checkExhaustedPredicates(parseState, workQueue, currentPosition);
      }

      // Neutral transfer: decrement from Step storage, increment into Global queue.
      for (var frame in currentStep.nextFrames) {
        parseState.decrementTrackers(frame.context, "transfer next");
        _enqueueFramesForPosition(parseState, workQueue, [frame]);
      }
      currentStep.nextFrames.clear();

      for (var frame in currentStep.requeued) {
        parseState.decrementTrackers(frame.context, "transfer requeue");
        _enqueueFramesForPosition(parseState, workQueue, [frame]);
      }
      currentStep.requeued.clear();
    }

    var steps = stepsAtPosition[currentPosition];

    // Harvest any frames enqueued for positions beyond currentPosition
    // (e.g., from negations or deferred sub-parses) and store in deferred map.
    while (workQueue.isNotEmpty) {
      var futurePos = workQueue.firstKeyOrNull!;
      var futureFrames = workQueue.removeFirst();

      for (var frame in futureFrames) {
        parseState.decrementTrackers(frame.context, "defer to Step.deferredFramesByPosition");
        steps?.deferredFramesByPosition.putIfAbsent(futurePos, () => []).add(frame);
      }
    }

    if (steps != null) {
      return steps;
    }

    var step = Step(
      parseState,
      token,
      currentPosition,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
    );
    step.finalize();
    return step;
  }
}

final class _PositionWorkQueue {
  final List<(int position, Frame frame)> _heap = [];

  bool get isEmpty => _heap.isEmpty;
  bool get isNotEmpty => _heap.isNotEmpty;

  int? get firstKeyOrNull => _heap.isEmpty ? null : _heap.first.$1;

  List<Frame> removeFirst() {
    if (_heap.isEmpty) {
      return const [];
    }

    var list = <Frame>[];
    var min = _heap.first.$1;

    while (_heap.isNotEmpty && _heap.first.$1 == min) {
      // Swap first and last
      var temp = _heap.first;
      _heap.first = _heap.last;
      _heap.last = temp;

      // Add the last element (which was the first) to the list
      list.add(_heap.last.$2);

      // Remove the last element
      _heap.removeLast();

      // Sift down if heap is not empty
      if (_heap.isNotEmpty) {
        _siftDown(0);
      }
    }

    return list;
  }

  void addFrame(int position, Frame frame) {
    _heap.add((position, frame));
    _siftUp(_heap.length - 1);
  }

  void _siftUp(int index) {
    while (index > 0) {
      int parent = (index - 1) >> 1;
      if (_heap[parent].$1 <= _heap[index].$1) {
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
      int smallest = index;
      int left = (index << 1) + 1;
      int right = (index << 1) + 2;

      if (left < _heap.length && _heap[left].$1 < _heap[smallest].$1) {
        smallest = left;
      }
      if (right < _heap.length && _heap[right].$1 < _heap[smallest].$1) {
        smallest = right;
      }

      if (smallest == index) {
        break;
      }

      var temp = _heap[index];
      _heap[index] = _heap[smallest];
      _heap[smallest] = temp;
      index = smallest;
    }
  }
}
