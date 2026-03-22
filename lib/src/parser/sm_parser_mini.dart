import 'dart:collection';

import 'package:glush/src/core/grammar.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/parser/state_machine.dart';
import 'common.dart';
import 'interface.dart';

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
///
/// Unlike the full [SMParser], this implementation does not build a Binary Subtree
/// Representation (BSR) or a Shared Packed Parse Forest (SPPF) by default. It is
/// optimized for cases where only the results (marks) are needed.
class SMParserMini implements GlushParser, Recognizer, MarksParser {
  static const Context _initialContext = Context(
    RootCallerKey(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  final StateMachine stateMachine;
  late final List<Frame> _initialFrames;

  final GlushListManager<Mark> markManager = GlushListManager<Mark>();

  final Map<int, TokenNode> historyByPosition = {};
  TokenNode? _historyTail;

  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};

  bool captureTokensAsMarks;

  GrammarInterface get grammar => stateMachine.grammar;

  SMParserMini(GrammarInterface grammar, {this.captureTokensAsMarks = false})
    : stateMachine = StateMachine(grammar) {
    _initInitialFrames();
  }

  SMParserMini.fromStateMachine(this.stateMachine, {this.captureTokensAsMarks = false}) {
    _initInitialFrames();
  }

  void _initInitialFrames() {
    final initialFrame = Frame(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

  @override
  bool recognize(String input) {
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        predecessors: {},
        captureTokensAsMarks: captureTokensAsMarks,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return false;
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      predecessors: {},
      captureTokensAsMarks: captureTokensAsMarks,
    );
    return lastStep.accept;
  }

  /// Standard parsing that returns the first valid result found.
  @override
  ParseOutcome parse(String input) {
    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        predecessors: {},
        captureTokensAsMarks: captureTokensAsMarks,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) return ParseError(position);
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      predecessors: {},
      captureTokensAsMarks: captureTokensAsMarks,
    );

    if (lastStep.accept) {
      return ParseSuccess(ParserResult(lastStep.marks));
    } else {
      return ParseError(position);
    }
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  @override
  ParseOutcome parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors = {};

    var frames = _initialFrames;
    var position = 0;

    for (final codepoint in input.codeUnits) {
      final stepResult = _processToken(
        codepoint,
        position,
        frames,
        isSupportingAmbiguity: true,
        captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        predecessors: predecessors,
      );
      frames = stepResult.nextFrames;
      if (frames.isEmpty) {
        return ParseError(position);
      }
      position++;
    }

    final lastStep = _processToken(
      null,
      position,
      frames,
      isSupportingAmbiguity: true,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
      predecessors: predecessors,
    );

    if (lastStep.accept) {
      final Map<ParseNodeKey, GlushList<Mark>> memo = {};
      final results = <GlushList<Mark>>[];

      for (final (state, context) in lastStep.acceptedContexts) {
        final rootNode = (state.id, position, context.caller);
        results.add(_extractForestFromGraph(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccess(markManager.branched(results));
    } else {
      return ParseError(position);
    }
  }

  GlushList<Mark> _extractForestFromGraph(
    ParseNodeKey node,
    Map<ParseNodeKey, GlushList<Mark>> memo,
    Map<ParseNodeKey, Set<PredecessorInfo>> predecessors, [
    Set<ParseNodeKey>? visiting,
  ]) {
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <ParseNodeKey>{};
    if (currentVisiting.contains(node)) {
      return const GlushList<Mark>.empty();
    }

    currentVisiting.add(node);
    final predecessorsForNode = predecessors[node];
    if (predecessorsForNode == null) return memo[node] = const GlushList<Mark>.empty();

    final alternatives = <GlushList<Mark>>[];
    for (final (source, action, marks, callSite) in predecessorsForNode) {
      if (action is ReturnAction) {
        final ruleForest = _extractForestFromGraph(source!, memo, predecessors, currentVisiting);
        final parentForest = callSite != null
            ? _extractForestFromGraph(callSite, memo, predecessors, currentVisiting)
            : const GlushList<Mark>.empty();
        alternatives.add(parentForest.addList(markManager, ruleForest));
      } else if (source != null) {
        final base = _extractForestFromGraph(source, memo, predecessors, currentVisiting);
        alternatives.add(base.addList(markManager, marks));
      } else {
        alternatives.add(marks);
      }
    }
    currentVisiting.remove(node);

    return memo[node] = markManager.branched(alternatives);
  }

  Step _processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    required Map<ParseNodeKey, Set<PredecessorInfo>> predecessors,
  }) {
    if (token != null) {
      final node = TokenNode(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      historyByPosition[currentPosition] = node;
    }

    if (_historyTail != null) {
      historyByPosition[currentPosition] = _historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    _enqueueFramesForPosition(workQueue, frames);

    while (workQueue.isNotEmpty) {
      final position = workQueue.firstKey()!;
      if (position > currentPosition) break;

      final positionFrames = workQueue.remove(position)!;

      final currentStep = stepsAtPosition.putIfAbsent(position, () {
        final positionToken = (position == currentPosition)
            ? token
            : historyByPosition[position]?.unit;
        return Step(
          this,
          positionToken,
          position,
          markManager: markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        );
      });

      for (final frame in positionFrames) {
        if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
          predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]?.activeFrames--;
        }
        currentStep.processFrame(frame);
      }

      if (workQueue.isEmpty || workQueue.firstKey()! > currentPosition) {
        _checkExhaustedPredicates(workQueue, currentPosition);
      }

      if (position < currentPosition) {
        _enqueueFramesForPosition(workQueue, currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }

      _enqueueFramesForPosition(workQueue, currentStep.requeued);
      currentStep.requeued.clear();
    }

    return stepsAtPosition[currentPosition] ??
        Step(
          this,
          token,
          currentPosition,
          markManager: markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        );
  }

  void _enqueueFramesForPosition(SplayTreeMap<int, List<Frame>> workQueue, List<Frame> frames) {
    for (final frame in frames) {
      final position = frame.context.pivot ?? 0;
      workQueue.putIfAbsent(position, () => []).add(frame);
    }
  }

  void _checkExhaustedPredicates(SplayTreeMap<int, List<Frame>> workQueue, int currentPosition) {
    bool changed = true;
    while (changed) {
      changed = false;
      final toRemove = <PredicateKey>{};
      for (final entry in predicateTrackers.entries) {
        final tracker = entry.value;

        if (tracker.activeFrames == 0 && !tracker.matched) {
          for (final (parentContext, nextState) in tracker.waiters) {
            final predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              final parentTracker =
                  predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              if (parentTracker != null) {
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPosition = parentContext.pivot ?? 0;
              workQueue
                  .putIfAbsent(targetPosition, () => [])
                  .add(Frame(parentContext)..nextStates.add(nextState));

              if (parentContext.predicateStack.lastOrNull case var parentPredicateKey?) {
                predicateTrackers[(parentPredicateKey.pattern, parentPredicateKey.startPosition)]
                    ?.activeFrames++;
              }
            }
          }
          toRemove.add(entry.key);
          changed = true;
        } else if (tracker.matched) {
          toRemove.add(entry.key);
        }
      }
      for (final key in toRemove) {
        predicateTrackers.remove(key);
      }
    }
  }
}
