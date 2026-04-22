/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
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

  void _resolveExhaustedPredicatesAt(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
    List<Object> items,
  ) {
    for (var item in items) {
      if (item is SubparseKey) {
        _handleTrackerExhaustion(parseState, workQueue, currentPosition, item);
      }
    }
  }

  void _processFramesAt(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    Map<int, Step> stepsAtPosition,
    bool isSupportingAmbiguity,
    bool captureTokensAsMarks,
    int currentPosition,
    int position,
    int? token,
    List<Object> items,
  ) {
    var step = stepsAtPosition[position] ??= Step(
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

    for (var item in items) {
      if (item is Frame) {
        parseState.decrementTrackers(item.context, "process position queue");
        step.processFrameEnqueue(item);
      }
    }

    step.processFrameFinalize();
    step.finalize();

    // Transfer survivors to next position
    for (var frame in step.nextFrames) {
      parseState.decrementTrackers(frame.context, "transfer next");
      _enqueueFrameForPosition(parseState, workQueue, frame);
    }
    step.nextFrames.clear();

    // Requeue frames for the same position (epsilon transitions)
    for (var frame in step.requeued) {
      parseState.decrementTrackers(frame.context, "transfer requeue");
      _enqueueFrameForPosition(parseState, workQueue, frame);
    }
    step.requeued.clear();
  }

  void _handleTrackerExhaustion(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
    SubparseKey key,
  ) {
    var tracker = parseState.trackers[key];
    if (tracker is! PredicateTracker || !tracker.canResolveFalse) {
      return;
    }

    tracker.exhausted = true;
    parseState.memoizePredicateOutcome(key as PredicateKey, isMatched: false);

    for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
      parseState.decrementTrackers(parentContext, "childExhausted");

      if (!tracker.isAnd) {
        var nextFrame = Frame(parentContext, parentMarks)..nextStates.add(nextState);
        _enqueueFrameForPosition(parseState, workQueue, nextFrame, reason: "resumeNotPredicate");
      }
    }
    tracker.waiters.clear();
    parseState.trackers.remove(key);
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

    var workQueue = _PositionWorkQueue();
    parseState.onTrackerExhausted = (key) {
      workQueue.addResolutionJob(currentPosition, key);
    };

    var stepsAtPosition = <int, Step>{};
    for (var frame in frames) {
      _enqueueFrameForPosition(parseState, workQueue, frame);
    }

    while (workQueue.isNotEmpty) {
      var priority = workQueue.firstPriorityOrNull!;
      var position = priority >> 1;
      var isResolutionPhase = (priority & 1) == 1;

      if (token != null && position > currentPosition) {
        break;
      }

      var items = workQueue.removeFirst();

      if (isResolutionPhase) {
        _resolveExhaustedPredicatesAt(parseState, workQueue, currentPosition, items);
        continue;
      }

      _processFramesAt(
        parseState,
        workQueue,
        stepsAtPosition,
        isSupportingAmbiguity,
        captureTokensAsMarks,
        currentPosition,
        position,
        token,
        items,
      );
    }

    var steps = stepsAtPosition[currentPosition];

    while (workQueue.isNotEmpty) {
      var priority = workQueue.firstPriorityOrNull!;
      var futurePos = priority >> 1;
      var items = workQueue.removeFirst();

      for (var item in items) {
        if (item is Frame) {
          parseState.decrementTrackers(item.context, "defer to Step.deferredFramesByPosition");
          steps?.deferredFramesByPosition.putIfAbsent(futurePos, () => []).add(item);
        }
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
    parseState.onTrackerExhausted = null;
    return step;
  }
}

/// A min-priority queue that sorts frames by their input position.
///
/// This ensures that the parser always processes tokens in chronological
/// order, which is essential for lookahead predicate resolution and
/// incremental parsing.
final class _PositionWorkQueue {
  final List<int> _priorities = [];
  final List<Object> _items = [];

  bool get isEmpty => _priorities.isEmpty;
  bool get isNotEmpty => _priorities.isNotEmpty;

  int? get firstPriorityOrNull => _priorities.isEmpty ? null : _priorities.first;

  List<Object> removeFirst() {
    if (_priorities.isEmpty) {
      return const [];
    }

    var list = <Object>[];
    var min = _priorities.first;

    while (_priorities.isNotEmpty && _priorities.first == min) {
      var last = _priorities.length - 1;
      var firstItem = _items.first;

      _priorities[0] = _priorities[last];
      _items[0] = _items[last];
      list.add(firstItem);

      _priorities.removeLast();
      _items.removeLast();

      if (_priorities.isNotEmpty) {
        _siftDown(0);
      }
    }

    return list;
  }

  void addFrame(int position, Frame frame) {
    _add((position << 1) | 0, frame);
  }

  void addResolutionJob(int position, SubparseKey key) {
    _add((position << 1) | 1, key);
  }

  void _add(int priority, Object item) {
    _priorities.add(priority);
    _items.add(item);
    _siftUp(_priorities.length - 1);
  }

  void _swap(int a, int b) {
    var priority = _priorities[a];
    _priorities[a] = _priorities[b];
    _priorities[b] = priority;

    var item = _items[a];
    _items[a] = _items[b];
    _items[b] = item;
  }

  void _siftUp(int index) {
    while (index > 0) {
      int parent = (index - 1) >> 1;
      if (_priorities[parent] <= _priorities[index]) {
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

      if (left < _priorities.length && _priorities[left] < _priorities[smallest]) {
        smallest = left;
      }
      if (right < _priorities.length && _priorities[right] < _priorities[smallest]) {
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
