/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:glush/src/parser/common/step.dart";
import "package:glush/src/parser/common/tracer.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_key.dart";

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
    // Repeat until no predicate resolution can trigger further parent updates.
    while (changed) {
      changed = false;
      var toRemove = <PredicateKey>{};
      // Resolving one predicate can unblock another predicate in the same pass.
      for (var entry in parseState.predicateTrackers.entries) {
        var tracker = entry.value;
        if (!tracker.exhausted && tracker.canResolveFalse) {
          // No live branches remain, so the predicate failed (success for NOT).
          tracker.exhausted = true;
          for (var (_, parentContext, nextState, parentMarks) in tracker.waiters) {
            var predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
              var parentTracker = parseState.predicateTrackers[key];
              if (parentTracker != null) {
                parentTracker.removePendingFrame();
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              var targetPosition = parentContext.position;
              var nextFrame = Frame(parentContext, parentMarks)..nextStates.add(nextState);
              if (parentContext.predicateStack.lastOrNull case var pk?) {
                var key = PredicateKey(pk.pattern, pk.startPosition);
                var parentTracker = parseState.predicateTrackers[key];
                if (parentTracker != null) {
                  parentTracker.addPendingFrame();
                }
              }
              workQueue.addFrame(targetPosition, nextFrame);
            }
          }
          tracker.waiters.clear();
          toRemove.add(entry.key);
          changed = true;
        } else if (tracker.matched || tracker.exhausted) {
          // Resolved predicates can be removed once their waiters drain.
          toRemove.add(entry.key);
        }
      }
      for (var key in toRemove) {
        parseState.predicateTrackers.remove(key);
      }
    }
  }

  /// Helper to enqueue a frame at a specific future position.
  void _enqueueAt(
    _PositionWorkQueue workQueue,
    int position,
    State state,
    Context context,
    GlushList<Mark> marks,
  ) {
    var frame = Frame(context, marks)..nextStates.add(state);
    workQueue.addFrame(position, frame);
  }

  /// Detect negations that are now fully exhausted and resume surviving waiters.
  void _checkExhaustedNegations(
    ParseState parseState,
    _PositionWorkQueue workQueue,
    int currentPosition,
  ) {
    var toRemove = <NegationKey>[];
    for (var entry in parseState.negationTrackers.entries) {
      var tracker = entry.value;
      if (tracker.isExhausted) {
        // Negation sub-parse is done. Resume any waiter for a position j
        // that was NEVER returned by the sub-parse A.
        for (var MapEntry(key: j, value: waiters) in tracker.waiters.entries) {
          if (!tracker.matchedPositions.contains(j)) {
            // Surviving waiter! Resume at j.
            for (var (context, nextState, marks) in waiters) {
              _enqueueAt(workQueue, j, nextState, context, marks);
            }
          }
        }
        // Keep the tracker in place so later candidate positions can resolve
        // immediately without respawning the child sub-parse.
        tracker.waiters.clear();

        // Unconstrained waiters: resume at every visited position A didn't match.
        if (tracker.unconstrainedWaiters.isNotEmpty) {
          for (var j in tracker.visitedPositions) {
            if (!tracker.matchedPositions.contains(j)) {
              for (var (context, nextState, marks) in tracker.unconstrainedWaiters) {
                workQueue.addFrame(
                  j,
                  Frame(context.copyWith(position: j), marks)..nextStates.add(nextState),
                );
              }
            }
          }
          tracker.unconstrainedWaiters.clear();
        }
        toRemove.add(entry.key);
      }
    }
    for (var key in toRemove) {
      parseState.negationTrackers.remove(key);
    }
  }

  /// Create a reusable manual parse cursor.
  ParseState createParseState({
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    ParseTracer? tracer,
  }) {
    return ParseState(
      this,
      initialFrames: initialFrames,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
      tracer: tracer ?? const NullTracer(),
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
    bool? captureTokensAsMarks,
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
      if (position > currentPosition) {
        break;
      }

      var positionFrames = workQueue.removeFirst();

      if (stepsAtPosition[position] == null) {
        // Build one Step object per position lazily on first visit.
        var positionToken = (position == currentPosition)
            ? token
            : parseState.historyByPosition[position];

        stepsAtPosition[position] = Step(
          parseState,
          positionToken,
          position,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        );
      }
      var currentStep = stepsAtPosition[position]!;

      // Process all frames' enqueueing first, then finalize work queue.
      // This is critical for proper ambiguity handling: when multiple frames
      // have the same state but different marks, they must be enqueued
      // BEFORE the work queue is processed, so that _currentFrameGroups
      // deduplication can merge their marks via GlushList.branched.
      for (var frame in positionFrames) {
        // Replay frames are bookkeeping-only, so they skip predicate counters.
        if (frame.context.predicateStack.lastOrNull case PredicateCallerKey pk) {
          // Contract note mirrors processFrame():
          // tracker can be absent after cleanup of an exhausted predicate.
          // Dequeued predicate-owned frame consumes one pending work unit.
          var key = PredicateKey(pk.pattern, pk.startPosition);
          var tracker = parseState.predicateTrackers[key];
          if (tracker != null) {
            tracker.removePendingFrame();
          }
        }
        if (frame.context.caller case ConjunctionCallerKey caller) {
          // Decrement pending frame counter for the conjunction sub-parse.
          var tracker = parseState
              .conjunctionTrackers[ConjunctionKey(caller.left, caller.right, caller.startPosition)];

          if (tracker != null && tracker.activeFrames > 0) {
            tracker.removePendingFrame();
          }
        }

        if (frame.context.caller case NegationCallerKey caller) {
          parseState
              .negationTrackers[NegationKey(caller.pattern, caller.startPosition)]
              ?.visitedPositions
              .add(position);
        }
        currentStep.processFrameEnqueue(frame);
      }
      currentStep.processFrameFinalize();

      currentStep.finalize();

      var nextQueuedPosition = workQueue.firstKeyOrNull;
      if (nextQueuedPosition == null || nextQueuedPosition > currentPosition) {
        // Logical meaning:
        // - either there is no queued work left, or
        // - the next queued position is strictly after `currentPosition`
        // => there is no more work that could still produce predicate matches
        // at/before this boundary, so exhaustion checks are safe now.
        _checkExhaustedPredicates(parseState, workQueue, currentPosition);
        _checkExhaustedNegations(parseState, workQueue, currentPosition);
      }

      if (position < currentPosition) {
        // Earlier positions can unlock future work after their token step ends.
        // Earlier positions may generate future-position token transitions.
        _enqueueFramesForPosition(parseState, workQueue, currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }

      _enqueueFramesForPosition(parseState, workQueue, currentStep.requeued);
      currentStep.requeued.clear();
    }

    var steps = stepsAtPosition[currentPosition];
    if (steps != null) {
      return steps;
    }

    var step = Step(
      parseState,
      token,
      currentPosition,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
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

    int minPos = _heap.first.$1;
    List<Frame> framesAtMin = [];

    // Extract all frames at minimum position
    int i = 0;
    while (i < _heap.length && _heap[i].$1 == minPos) {
      framesAtMin.add(_heap[i].$2);
      i++;
    }

    // Remove extracted elements and maintain heap invariant
    _heap.removeRange(0, i);

    return framesAtMin;
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
}
