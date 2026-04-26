/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/sm_parser.dart" show SMParser;
import "package:glush/src/parser/state_machine/state_machine.dart";

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

  void _enqueueFramesByPosition(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    List<Frame> frames, {
    String decrementReason = "transfer batch",
    String enqueueReason = "enqueue list",
    List<PredicateKey>? exhaustedPredicates,
  }) {
    if (frames.isEmpty) {
      return;
    }

    var buckets = <int, List<Frame>>{};
    for (var frame in frames) {
      var decrementedTracker = parseState.decrementTracker(frame.context, decrementReason);
      if (decrementedTracker != null) {
        exhaustedPredicates?.add(decrementedTracker);
      }

      parseState.incrementTrackers(frame.context, enqueueReason);
      buckets.putIfAbsent(frame.context.position, () => []).add(frame);
    }

    buckets.forEach(workQueue.addFrames);
  }

  void _resolveExhaustedPredicates(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
    List<PredicateKey> exhaustedPredicates,
  ) {
    while (exhaustedPredicates.isNotEmpty) {
      var key = exhaustedPredicates.removeLast();
      _handleTrackerExhaustion(parseState, workQueue, currentPosition, key, exhaustedPredicates);
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
    int? lookahead,
    List<Frame> items,
  ) {
    var exhaustedPredicates = <PredicateKey>[];

    var stepToken = position < parseState.historyByPosition.length
        ? parseState.historyByPosition[position]
        : null;
    int? stepLookahead;
    if (position + 1 < parseState.historyByPosition.length) {
      stepLookahead = parseState.historyByPosition[position + 1];
    } else if (position == currentPosition) {
      stepLookahead = lookahead;
    }

    var step = stepsAtPosition[position] ??= Step(
      parseState,
      stepToken,
      position,
      lookahead: stepLookahead,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
    );
    step.exhaustedPredicatesSink = exhaustedPredicates;

    for (var item in items) {
      var decrementedTracker = parseState.decrementTracker(item.context, "process position queue");
      if (decrementedTracker != null) {
        exhaustedPredicates.add(decrementedTracker);
      }
      step.processFrameEnqueue(item);
    }

    step.processFrameFinalize();
    step.finalize();

    // Transfer survivors in position batches (reduces queue churn for lagging paths).
    _enqueueFramesByPosition(
      parseState,
      workQueue,
      step.nextFrames,
      decrementReason: "transfer next",
      exhaustedPredicates: exhaustedPredicates,
    );
    step.nextFrames.clear();

    // Requeue epsilon/lagging frames in position batches.
    _enqueueFramesByPosition(
      parseState,
      workQueue,
      step.requeued,
      decrementReason: "transfer requeue",
      exhaustedPredicates: exhaustedPredicates,
    );
    step.requeued.clear();

    _resolveExhaustedPredicates(parseState, workQueue, currentPosition, exhaustedPredicates);
  }

  void _handleTrackerExhaustion(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
    PredicateKey key,
    List<PredicateKey> exhaustedPredicates,
  ) {
    var tracker = parseState.trackers[key];
    if (tracker is! PredicateTracker<State> || !parseState.canResolvePredicateFalse(key, tracker)) {
      return;
    }

    tracker.exhausted = true;
    parseState.memoizePredicateOutcome(key, isMatched: false);

    for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
      var decrementedTracker = parseState.decrementTracker(parentContext, "childExhausted");
      if (decrementedTracker != null) {
        exhaustedPredicates.add(decrementedTracker);
      }

      if (!tracker.isAnd) {
        var nextFrame = Frame(parentContext, parentMarks)..nextStates.add(nextState);
        _enqueueFrameForPosition(parseState, workQueue, nextFrame, reason: "resumeNotPredicate");
      }
    }
    tracker.waiters.clear();
    parseState.removeTracker(key);
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
    int? lookahead,
    bool isSupportingAmbiguity = false,
    bool captureTokensAsMarks = false,
  }) {
    var workQueue = _PositionWorkQueue();

    var stepsAtPosition = <int, Step>{};
    for (var frame in frames) {
      _enqueueFrameForPosition(parseState, workQueue, frame);
    }

    while (workQueue.isNotEmpty) {
      var position = workQueue.firstPriorityOrNull!;

      if (token != null && position > currentPosition) {
        break;
      }

      var items = workQueue.removeFirst();

      _processFramesAt(
        parseState,
        workQueue,
        stepsAtPosition,
        isSupportingAmbiguity,
        captureTokensAsMarks,
        currentPosition,
        position,
        token,
        lookahead,
        items,
      );
    }

    var steps = stepsAtPosition[currentPosition];

    while (workQueue.isNotEmpty) {
      var futurePos = workQueue.firstPriorityOrNull!;
      var items = workQueue.removeFirst();

      for (var item in items) {
        parseState.decrementTracker(item.context, "defer to Step.deferredFramesByPosition");
        steps?.deferredFramesByPosition.putIfAbsent(futurePos, () => []).add(item);
      }
    }

    if (steps != null) {
      return steps;
    }

    var step = Step(
      parseState,
      token,
      currentPosition,
      lookahead: lookahead,
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
  final List<int> _priorities = [];
  final Map<int, List<Frame>> _itemsByPosition = {};

  bool get isEmpty => _priorities.isEmpty;
  bool get isNotEmpty => _priorities.isNotEmpty;

  int? get firstPriorityOrNull => _priorities.isEmpty ? null : _priorities.first;

  List<Frame> removeFirst() {
    if (_priorities.isEmpty) {
      return const <Frame>[];
    }

    var min = _priorities.first;
    var items = _itemsByPosition.remove(min) ?? const <Frame>[];

    var last = _priorities.length - 1;
    _priorities[0] = _priorities[last];
    _priorities.removeLast();

    if (_priorities.isNotEmpty) {
      _siftDown(0);
    }

    return items;
  }

  void addFrame(int position, Frame frame) {
    var existing = _itemsByPosition[position];
    if (existing != null) {
      existing.add(frame);
      return;
    }

    _itemsByPosition[position] = [frame];
    _addPriority(position);
  }

  void addFrames(int position, List<Frame> frames) {
    if (frames.isEmpty) {
      return;
    }

    var existing = _itemsByPosition[position];
    if (existing != null) {
      existing.addAll(frames);
      return;
    }

    _itemsByPosition[position] = List<Frame>.from(frames);
    _addPriority(position);
  }

  void _addPriority(int priority) {
    _priorities.add(priority);
    _siftUp(_priorities.length - 1);
  }

  void _swap(int a, int b) {
    var priority = _priorities[a];
    _priorities[a] = _priorities[b];
    _priorities[b] = priority;
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
