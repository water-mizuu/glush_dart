/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/glush.dart" show SMParser;
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/sm_parser.dart" show SMParser;

/// An abstract base class providing the core logic for a state-machine parser.
///
/// [GlushParserBase] implements the heavy lifting of the Glush parsing algorithm,
/// including the work-queue management, lookahead predicate resolution, and
/// token processing loop. It is designed to be subclassed by specific parser
/// implementations (like [SMParser]).
///
/// The base class manages the [processToken] loop, which coordinates:
/// - Advancing multiple concurrent parse paths (frames).
/// - Handling "lagging" frames that need to catch up to the current position.
/// - Resolving lookahead predicates as they succeed or exhaust.
/// - Transitioning between input positions using a priority-ordered work queue.
abstract base class GlushParserBase implements GlushParser {
  /// The initial set of frames to start the parsing process.
  @override
  List<Frame> get initialFrames;

  void _enqueueFrameForPosition(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    Frame frame, {
    String reason = "enqueue list",
  }) {
    parseState.incrementTrackers(frame.context, reason);
    workQueue.addFrame(frame.context.position, frame);
  }

  void _checkExhaustedPredicates(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
  ) {
    while (true) {
      var pending = parseState.takePendingPredicateExhaustion();
      if (pending.isEmpty) {
        break;
      }

      for (var key in pending) {
        var tracker = parseState.trackers[key];
        if (tracker is! PredicateTracker) {
          continue;
        }
        if (tracker.matched || tracker.exhausted || !tracker.canResolveFalse) {
          continue;
        }

        tracker.exhausted = true;
        for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
          parseState.decrementTrackers(parentContext, "childExhausted");

          if (!tracker.isAnd) {
            var nextFrame = Frame(parentContext, parentMarks)..nextStates.add(nextState);
            _enqueueFrameForPosition(
              parseState,
              workQueue,
              nextFrame,
              reason: "resumeNotPredicate",
            );
          }
        }
        tracker.waiters.clear();
        parseState.trackers.remove(key);
      }
    }
  }

  /// Creates a new [ParseState] initialized with this parser's grammar and
  /// configuration.
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

  /// Processes a single [token] and advances all active parse paths.
  ///
  /// This is the core of the incremental parsing engine. It handles:
  /// 1. Token replay for frames that are behind the current position.
  /// 2. Advancing states through the state machine.
  /// 3. Managing the work queue to ensure that frames are processed in
  ///    positional order.
  /// 4. Finalizing acceptance status once the end-of-input (null token) is
  ///    reached.
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
    for (var frame in frames) {
      _enqueueFrameForPosition(parseState, workQueue, frame);
    }

    while (workQueue.isNotEmpty) {
      var position = workQueue.firstKeyOrNull!;
      if (token != null && position > currentPosition) {
        break;
      }

      var positionFrames = workQueue.removeFirst();

      if (stepsAtPosition[position] == null) {
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

      for (var frame in currentStep.nextFrames) {
        parseState.decrementTrackers(frame.context, "transfer next");
        _enqueueFrameForPosition(parseState, workQueue, frame);
      }
      currentStep.nextFrames.clear();

      for (var frame in currentStep.requeued) {
        parseState.decrementTrackers(frame.context, "transfer requeue");
        _enqueueFrameForPosition(parseState, workQueue, frame);
      }
      currentStep.requeued.clear();
    }

    var steps = stepsAtPosition[currentPosition];

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

/// A min-priority queue that sorts frames by their input position.
///
/// This ensures that the parser always processes tokens in chronological
/// order, which is essential for lookahead predicate resolution and
/// incremental parsing.
final class _PositionWorkQueue {
  final List<int> _positions = [];
  final List<Frame> _frames = [];

  bool get isEmpty => _positions.isEmpty;
  bool get isNotEmpty => _positions.isNotEmpty;

  int? get firstKeyOrNull => _positions.isEmpty ? null : _positions.first;

  List<Frame> removeFirst() {
    if (_positions.isEmpty) {
      return const [];
    }

    var list = <Frame>[];
    var min = _positions.first;

    while (_positions.isNotEmpty && _positions.first == min) {
      var last = _positions.length - 1;
      var firstFrame = _frames.first;

      _positions[0] = _positions[last];
      _frames[0] = _frames[last];
      list.add(firstFrame);

      _positions.removeLast();
      _frames.removeLast();

      if (_positions.isNotEmpty) {
        _siftDown(0);
      }
    }

    return list;
  }

  void addFrame(int position, Frame frame) {
    _positions.add(position);
    _frames.add(frame);
    _siftUp(_positions.length - 1);
  }

  void _swap(int a, int b) {
    var position = _positions[a];
    _positions[a] = _positions[b];
    _positions[b] = position;

    var frame = _frames[a];
    _frames[a] = _frames[b];
    _frames[b] = frame;
  }

  void _siftUp(int index) {
    while (index > 0) {
      int parent = (index - 1) >> 1;
      if (_positions[parent] <= _positions[index]) {
        break;
      }
      _swap(parent, index);
      index = parent;
    }
  }

  void _siftDown(int index) {
    while (true) {
      int smallest = index;
      int left = (index << 1) + 1;
      int right = (index << 1) + 2;

      if (left < _positions.length && _positions[left] < _positions[smallest]) {
        smallest = left;
      }
      if (right < _positions.length && _positions[right] < _positions[smallest]) {
        smallest = right;
      }

      if (smallest == index) {
        break;
      }

      _swap(index, smallest);
      index = smallest;
    }
  }
}
