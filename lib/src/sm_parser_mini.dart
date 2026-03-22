import 'dart:collection';

import 'package:glush/src/grammar.dart';
import 'package:glush/src/list.dart';
import 'package:glush/src/mark.dart';
import 'package:glush/src/patterns.dart';
import 'package:glush/src/state_machine.dart';

typedef PredicateKeyMini = (PatternSymbol pattern, int startPos);
typedef ContextKeyMini = (
  State state,
  CallerKeyMini caller,
  int? minPrecedenceLevel,
  GlushList<PredicateCallerKeyMini> predicateStack,
);
typedef CallerCacheKeyMini = (Rule rule, int startPos, int? minPrecedenceLevel);
typedef AcceptedContextMini = (State state, ContextMini context);
typedef ParseNodeKeyMini = (int stateId, int position, Object? caller);
typedef PredecessorInfoMini = (
  ParseNodeKeyMini? source,
  StateAction? action,
  GlushList<Mark> marks,
  ParseNodeKeyMini? callSite,
);
typedef WaiterInfoMini = (
  CallerKeyMini? parent,
  State next,
  int? minPrecedence,
  ContextMini callerContext,
  ParseNodeKeyMini node,
);

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
///
/// Unlike the full [SMParser], this implementation does not build a Binary Subtree
/// Representation (BSR) or a Shared Packed Parse Forest (SPPF) by default. It is
/// optimized for cases where only the results (marks) are needed.
///
/// Architecture:
/// - **Breadth-First Processing**: Processes input token-by-token.
/// - **Work Queue**: Uses a [SplayTreeMap] as a work queue for each position,
///   handling non-consuming actions (like rule returns or markers) before moving
///   to the next input position.
/// - **Predicate Tracking**: Manages lookahead predicates (& and !) using a
///   ref-counting mechanism ([PredicateTrackerMini]) to detect when a predicate
///   search has successfully exhausted all possibilities.
class SMParserMini {
  static const ContextMini _initialContext = ContextMini(
    RootCallerKeyMini(),
    GlushList.empty(),
    predicateStack: GlushList.empty(),
  );

  final StateMachine stateMachine;
  late final List<FrameMini> _initialFrames;
  final GlushListManager<Mark> _markManager = GlushListManager<Mark>();
  final GlushListManager<PredicateCallerKeyMini> _predicateStackManager =
      GlushListManager<PredicateCallerKeyMini>();
  final Map<int, TokenNodeMini> _historyByPosition = {};
  TokenNodeMini? _historyTail;
  final Map<PredicateKeyMini, PredicateTrackerMini> _predicateTrackers = {};

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
    final initialFrame = FrameMini(_initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }

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
  ParseOutcomeMini parse(String input) {
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
      if (frames.isEmpty) return ParseErrorMini(position);
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
      return ParseSuccessMini(ParserResultMini(lastStep.marks));
    } else {
      return ParseErrorMini(position);
    }
  }

  /// Parses ambiguous input and returns a forest of all possible results (marks).
  ///
  /// This method enables ambiguity support by tracking predecessors in a graph
  /// structure, allowing for the reconstruction of all valid parse trees' marks.
  ParseOutcomeMini parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    final Map<ParseNodeKeyMini, Set<PredecessorInfoMini>> predecessors = {};

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
        return ParseErrorMini(position);
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
      final Map<ParseNodeKeyMini, GlushList<Mark>> memo = {};
      final results = <GlushList<Mark>>[];

      for (final (state, context) in lastStep._acceptedContexts) {
        final rootNode = (state.id, position, context.caller);
        results.add(_extractForestFromGraph(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccessMini(_markManager.branched(results));
    } else {
      return ParseErrorMini(position);
    }
  }

  GlushList<Mark> _extractForestFromGraph(
    ParseNodeKeyMini node,
    Map<ParseNodeKeyMini, GlushList<Mark>> memo,
    Map<ParseNodeKeyMini, Set<PredecessorInfoMini>> predecessors, [
    Set<ParseNodeKeyMini>? visiting,
  ]) {
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <ParseNodeKeyMini>{};
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
        alternatives.add(parentForest.addList(_markManager, ruleForest));
      } else if (source != null) {
        final base = _extractForestFromGraph(source, memo, predecessors, currentVisiting);
        alternatives.add(base.addList(_markManager, marks));
      } else {
        alternatives.add(marks);
      }
    }
    currentVisiting.remove(node);

    return memo[node] = _markManager.branched(alternatives);
  }

  /// Main entry point for processing a single token at a given position.
  ///
  /// This method coordinates the breadth-first exploration of the state machine.
  /// It manages a [workQueue] that prioritizes frames by their "pivot" (position).
  ///
  /// The [SplayTreeMap] ensures that all non-consuming transitions (like epsilon,
  /// markers, or rule returns) at the *current* or *past* positions are fully
  /// processed before the parser advances to the next token.
  StepMini _processToken(
    int? token,
    int currentPosition,
    List<FrameMini> frames, {
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    required Map<ParseNodeKeyMini, Set<PredecessorInfoMini>> predecessors,
  }) {
    if (token != null) {
      final node = TokenNodeMini(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      _historyByPosition[currentPosition] = node;
    }

    if (_historyTail != null) {
      _historyByPosition[currentPosition] = _historyTail!;
    }

    final stepsAtPosition = <int, StepMini>{};
    final workQueue = SplayTreeMap<int, List<FrameMini>>((a, b) => a.compareTo(b));

    _enqueueFramesForPosition(workQueue, frames);

    while (workQueue.isNotEmpty) {
      final position = workQueue.firstKey()!;
      if (position > currentPosition) break;

      final positionFrames = workQueue.remove(position)!;

      final currentStep = stepsAtPosition.putIfAbsent(position, () {
        final positionToken = (position == currentPosition)
            ? token
            : _historyByPosition[position]?.unit;
        return StepMini(
          this,
          positionToken,
          position,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        );
      });

      for (final frame in positionFrames) {
        if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
          _predicateTrackers[(predicateKey.pattern, predicateKey.startPos)]?.activeFrames--;
        }
        currentStep._processFrame(frame);
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
        StepMini(
          this,
          token,
          currentPosition,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        );
  }

  void _enqueueFramesForPosition(
    SplayTreeMap<int, List<FrameMini>> workQueue,
    List<FrameMini> frames,
  ) {
    for (final frame in frames) {
      final position = frame.context.pivot ?? 0;
      workQueue.putIfAbsent(position, () => []).add(frame);

      if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
        _predicateTrackers[(predicateKey.pattern, predicateKey.startPos)]?.activeFrames++;
      }
    }
  }

  /// Analyzes predicates that may have completed due to exhaustion of all paths.
  ///
  /// A predicate (& or !) doesn't "return" a value; it succeeds or fails based on
  /// whether the parser can find *any* path matching the predicate pattern.
  ///
  /// If [activeFrames] drops to 0 for a tracker, we know we've explored all
  /// possible paths for that lookahead.
  /// - For & (AND): Failure to find a match means the predicate fails.
  /// - For ! (NOT): Failure to find a match means the predicate *succeeds*.
  void _checkExhaustedPredicates(
    SplayTreeMap<int, List<FrameMini>> workQueue,
    int currentPosition,
  ) {
    bool changed = true;
    while (changed) {
      changed = false;
      final toRemove = <(PatternSymbol, int)>{};
      for (final entry in _predicateTrackers.entries) {
        final tracker = entry.value;

        if (tracker.activeFrames == 0 && !tracker.matched) {
          for (final (parentContext, nextState) in tracker.waiters) {
            final predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              final parentTracker =
                  _predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
              if (parentTracker != null) {
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPosition = parentContext.pivot ?? 0;
              workQueue
                  .putIfAbsent(targetPosition, () => [])
                  .add(FrameMini(parentContext)..nextStates.add(nextState));

              if (parentContext.predicateStack.lastOrNull case var parentPredicateKey?) {
                _predicateTrackers[(parentPredicateKey.pattern, parentPredicateKey.startPos)]
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
        _predicateTrackers.remove(key);
      }
    }
  }
}

/// Sealed result type returned by [SMParserMini.parse].
sealed class ParseOutcomeMini {}

final class ParseErrorMini extends ParseOutcomeMini implements Exception {
  final int position;
  ParseErrorMini(this.position);
  @override
  String toString() => 'ParseError at position $position';
}

final class ParseSuccessMini extends ParseOutcomeMini {
  final ParserResultMini result;
  ParseSuccessMini(this.result);
}

final class ParseAmbiguousForestSuccessMini extends ParseOutcomeMini {
  final GlushList<Mark> forest;
  ParseAmbiguousForestSuccessMini(this.forest);
}

class ParserResultMini {
  final List<Mark> _rawMarks;
  ParserResultMini(this._rawMarks);

  List<String> get marks => _rawMarks.toShortMarks();

  List<List<Object?>> toList() => _rawMarks.map((mark) {
    if (mark is NamedMark) return mark.toList();
    if (mark is StringMark) return mark.toList();
    return [];
  }).toList();
}

class TokenNodeMini {
  final int unit;
  TokenNodeMini? next;
  TokenNodeMini(this.unit);
}

class PredicateTrackerMini {
  final PatternSymbol symbol;
  final int startPos;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(ContextMini, State)> waiters = [];
  PredicateTrackerMini(this.symbol, this.startPos, {required this.isAnd});
}

sealed class CallerKeyMini {
  const CallerKeyMini();
}

final class RootCallerKeyMini extends CallerKeyMini {
  const RootCallerKeyMini();
  @override
  int get hashCode => 0;
  @override
  bool operator ==(Object other) => other is RootCallerKeyMini;
}

final class PredicateCallerKeyMini extends CallerKeyMini {
  final PatternSymbol pattern;
  final int startPos;
  const PredicateCallerKeyMini(this.pattern, this.startPos);
  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKeyMini && pattern == other.pattern && startPos == other.startPos;
  @override
  int get hashCode => Object.hash(pattern, startPos);
}

/// A "lite" version of a GSS (Graph-Shared Stack) node.
///
/// [CallerMini] represents a rule call at a specific [startPos]. It tracks:
/// - **Waiters**: Other states waiting for this rule to finish so they can continue.
/// - **Returns**: Results (contexts) produced by this rule, which are then
///   pushed back to all waiters.
///
/// This structure effectively deduplicates rule calls: if two paths call the same
/// rule at the same position, they will share the same [CallerMini].
final class CallerMini extends CallerKeyMini {
  final Rule rule;
  final Pattern pattern;
  final int startPos;
  final int? minPrecedenceLevel;
  final List<WaiterInfoMini> waiters = [];
  final List<ContextMini> returns = [];

  CallerMini(this.rule, this.pattern, this.startPos, this.minPrecedenceLevel);

  bool addWaiter(
    CallerKeyMini? parent,
    State next,
    int? minPrecedence,
    ContextMini callerContext,
    ParseNodeKeyMini node,
  ) {
    for (final (p, n, m, c, _) in waiters) {
      if (p == parent && n == next && m == minPrecedence && c == callerContext) {
        return false;
      }
    }
    waiters.add((parent, next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(ContextMini context) {
    if (returns.contains(context)) return false;
    returns.add(context);
    return true;
  }

  void forEach(void Function(CallerKeyMini?, State, int?, ContextMini, ParseNodeKeyMini) callback) {
    for (final (key, state, minPrecedence, context, node) in waiters) {
      callback(key, state, minPrecedence, context, node);
    }
  }
}

/// Represents the full state of a parsing path at a specific point.
///
/// [ContextMini] is immutable and is passed through the state machine.
/// It carries:
/// - **Marks**: Semantic results collected so far.
/// - **Predicate Stack**: Active lookahead predicates to handle nesting correctly.
/// - **Precedence**: Information for handling operator precedence grammars.
class ContextMini {
  final CallerKeyMini caller;
  final GlushList<Mark> marks;
  final GlushList<PredicateCallerKeyMini> predicateStack;
  final int? callStart;
  final int? pivot;
  final TokenNodeMini? tokenHistory;
  final int? minPrecedenceLevel;
  final int? precedenceLevel;

  const ContextMini(
    this.caller,
    this.marks, {
    this.predicateStack = const GlushList.empty(),
    this.callStart,
    this.pivot,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  });

  ContextMini copyWith({
    CallerKeyMini? caller,
    GlushList<Mark>? marks,
    GlushList<PredicateCallerKeyMini>? predicateStack,
    int? callStart,
    int? pivot,
    TokenNodeMini? tokenHistory,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return ContextMini(
      caller ?? this.caller,
      marks ?? this.marks,
      predicateStack: predicateStack ?? this.predicateStack,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
      tokenHistory: tokenHistory ?? this.tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }
}

class FrameMini {
  final ContextMini context;
  final Set<State> nextStates;
  FrameMini(this.context) : nextStates = {};
  FrameMini copy() => FrameMini(context);
  CallerKeyMini? get caller => context.caller;
  GlushList<Mark> get marks => context.marks;
}

/// A single step of the parser at a specific [position].
///
/// A [StepMini] instance processes all [FrameMini]s that have arrived at this
/// position. It iterates through their next states and performs [StateAction]s.
///
/// Actions can:
/// - Transition to the *next* token position (stored in [nextFrames]).
/// - Trigger a rule call or return (which might add more work at the *current* position).
/// - Manage predicates.
class StepMini {
  final SMParserMini parser;
  final int? token;
  final int position;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final GlushListManager<Mark> markManager;
  final Map<ParseNodeKeyMini, Set<PredecessorInfoMini>> predecessors;
  final List<FrameMini> nextFrames = [];
  final Map<ContextKeyMini, List<GlushList<Mark>>> _nextFrameGroups = {};
  final Map<ContextKeyMini, Set<PredecessorInfoMini>> _nextPredecessorGroups = {};
  final Map<ContextKeyMini, GlushList<Mark>> _activeContexts = {};
  final Queue<AcceptedContextMini> _currentWorkList = DoubleLinkedQueue();
  final Map<CallerCacheKeyMini, CallerMini> _callers = {};
  final Set<CallerKeyMini> _returnedCallers = {};
  final List<AcceptedContextMini> _acceptedContexts = [];
  final List<FrameMini> requeued = [];

  void _requeue(FrameMini frame) {
    requeued.add(frame);
    if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
      parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)]?.activeFrames++;
    }
  }

  StepMini(
    this.parser,
    this.token,
    this.position, {
    required this.markManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    required this.predecessors,
  });

  void _finishPredicate(PredicateTrackerMini tracker, bool matched) {
    if (matched) {
      tracker.matched = true;
      for (final (parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          final parentTracker =
              parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
          parentTracker?.activeFrames--;
        }

        if (tracker.isAnd) {
          _requeue(FrameMini(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
    } else if (tracker.activeFrames == 0) {
      for (final (parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          final parentTracker =
              parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
          parentTracker?.activeFrames--;
        }

        if (!tracker.isAnd) {
          _requeue(FrameMini(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
    }
  }

  int? _getTokenFor(FrameMini frame) {
    final framePos = frame.context.pivot ?? 0;
    if (framePos == position) return token;
    return parser._historyByPosition[framePos]?.unit;
  }

  bool get accept => _acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    if (_acceptedContexts.isEmpty) return [];
    return _acceptedContexts[0].$2.marks.toList().cast<Mark>();
  }

  /// Enqueues a state to be processed at a specific position.
  ///
  /// If the [targetPosition] is the current position, the state is added to the
  /// [_currentWorkList] to be processed immediately. Otherwise, it is requeued
  /// to the parser's main work queue.
  void _enqueue(
    State state,
    ContextMini context, {
    ParseNodeKeyMini? source,
    StateAction? action,
    GlushList<Mark> marks = const GlushList.empty(),
    ParseNodeKeyMini? callSite,
  }) {
    final targetPosition = context.pivot ?? 0;
    if (targetPosition != position) {
      _requeue(FrameMini(context)..nextStates.add(state));
      return;
    }

    final key = (state, context.caller, context.minPrecedenceLevel, context.predicateStack);
    if (isSupportingAmbiguity) {
      if (source != null) {
        final target = (state.id, position, context.caller);
        predecessors.putIfAbsent(target, () => {}).add((source, action, marks, callSite));
      }

      final existingMarks = _activeContexts[key];
      if (existingMarks != null) return;
      _activeContexts[key] = context.marks;
    } else {
      if (_activeContexts.containsKey(key)) return;
      _activeContexts[key] = context.marks;
    }

    final predicateKey = context.predicateStack.lastOrNull;
    if (predicateKey != null) {
      final tracker = parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
      if (tracker != null) {
        tracker.activeFrames++;
      }
    }

    _currentWorkList.add((state, context));
  }

  void _process(FrameMini frame, State state) {
    for (final action in state.actions) {
      switch (action) {
        case SemanticAction():
          _enqueue(
            action.nextState,
            ContextMini(
              frame.caller ?? const RootCallerKeyMini(),
              frame.marks,
              predicateStack: frame.context.predicateStack,
              callStart: frame.context.callStart,
              pivot: frame.context.pivot,
              tokenHistory: frame.context.tokenHistory,
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
          );
        case TokenAction():
          final token = _getTokenFor(frame);
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            final pattern = action.pattern;
            bool shouldCapture = captureTokensAsMarks;
            if (pattern is Token && pattern.choice is! ExactToken) {
              shouldCapture = true;
            }

            if (shouldCapture) {
              newMarks = newMarks.add(
                markManager,
                StringMark(String.fromCharCode(token), position),
              );
            }

            final nextKey = (
              action.nextState,
              frame.caller ?? const RootCallerKeyMini(),
              frame.context.minPrecedenceLevel,
              frame.context.predicateStack,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
            if (isSupportingAmbiguity) {
              final source = (state.id, position, frame.context.caller);
              final deltaMarks = shouldCapture
                  ? const GlushList<Mark>.empty().add(
                      markManager,
                      StringMark(String.fromCharCode(token), position),
                    )
                  : const GlushList<Mark>.empty();
              _nextPredecessorGroups.putIfAbsent(nextKey, () => {}).add((
                source,
                action,
                deltaMarks,
                null,
              ));
            }
          }
        case MarkAction():
          final mark = NamedMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            ContextMini(
              frame.caller ?? const RootCallerKeyMini(),
              frame.marks.add(markManager, mark),
              predicateStack: frame.context.predicateStack,
              callStart: frame.context.callStart,
              pivot: frame.context.pivot,
              tokenHistory: frame.context.tokenHistory,
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
            marks: deltaMarks,
          );
        case PredicateAction():
          // Handling a Lookahead Predicate (& or !)
          // 1. Initialize a PredicateTracker to track the progress of the lookahead.
          // 2. Start a sub-parser at the current position.
          // 3. Mark the current path as 'waiting' for the tracker to complete.
          final symbol = action.symbol;
          final subParseKey = (symbol, position);
          final isFirst = !parser._predicateTrackers.containsKey(subParseKey);
          final tracker = parser._predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTrackerMini(symbol, position, isAnd: action.isAnd),
          );

          if (tracker.matched) {
            if (tracker.isAnd) {
              _requeue(FrameMini(frame.context)..nextStates.add(action.nextState));
            }
          } else {
            tracker.waiters.add((frame.context, action.nextState));
          }

          final predicateKey = frame.context.predicateStack.lastOrNull;
          if (predicateKey != null) {
            final parentTracker =
                parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
            parentTracker?.activeFrames++;
          }

          if (isFirst && !tracker.matched) {
            final states = parser.stateMachine.ruleFirst[symbol];
            if (states == null) {
              throw StateError('Predicate symbol must resolve to a rule: $symbol');
            }
            final newPredicateKey = PredicateCallerKeyMini(symbol, position);
            final nextStack = parser._predicateStackManager.push(
              frame.context.predicateStack,
              newPredicateKey,
            );

            for (final firstState in states) {
              _enqueue(
                firstState,
                ContextMini(
                  newPredicateKey,
                  const GlushList.empty(),
                  predicateStack: nextStack,
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                ),
              );
            }
          }
        case CallAction():
          // Handling a Rule Call (Standard GSS push)
          // 1. Find or create a Caller for (rule, position).
          // 2. Add the current frame as a 'waiter' to that Caller.
          // 3. If it's a new Caller, start processing the rule's initial states.
          // 4. If the Caller already has results (returns), trigger them for the new waiter.
          final key = (action.rule, position, action.minPrecedenceLevel);
          final isNewCaller = !_callers.containsKey(key);
          final caller = _callers.putIfAbsent(
            key,
            () => CallerMini(action.rule, action.pattern, position, action.minPrecedenceLevel),
          );
          final isNewWaiter = caller.addWaiter(
            frame.caller,
            action.returnState,
            action.minPrecedenceLevel,
            frame.context,
            (state.id, position, frame.context.caller),
          );

          if (isNewCaller) {
            final states = parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
            for (final firstState in states) {
              _enqueue(
                firstState,
                ContextMini(
                  caller,
                  const GlushList.empty(),
                  predicateStack: frame.context.predicateStack,
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                  minPrecedenceLevel: action.minPrecedenceLevel,
                ),
              );
            }
          } else if (isNewWaiter) {
            for (final returnContext in caller.returns) {
              _triggerReturn(
                caller,
                frame.caller,
                action.returnState,
                action.minPrecedenceLevel,
                frame.context,
                returnContext,
                source: (state.id, position, caller),
                action: action,
                callSite: (state.id, position, frame.context.caller),
              );
            }
          }
        case ReturnAction():
          // Handling a Rule Return (Standard GSS pop)
          // 1. Check precedence level (Earley-style precedence).
          // 2. Add the current context as a 'return' to the Caller.
          // 3. Trigger continuation for all 'waiters' currently waiting on this Caller.
          if (frame.context.minPrecedenceLevel != null &&
              action.precedenceLevel != null &&
              action.precedenceLevel! < frame.context.minPrecedenceLevel!)
            continue;
          if (_getTokenFor(frame) case var t?
              when action.rule.guard != null && !action.rule.guard!.match(t))
            continue;

          final caller = frame.caller;

          if (caller is PredicateCallerKeyMini) {
            final tracker = parser._predicateTrackers[(caller.pattern, caller.startPos)];
            if (tracker != null) {
              _finishPredicate(tracker, true);
            }
            continue;
          }

          if (!isSupportingAmbiguity && !_returnedCallers.add(caller ?? const RootCallerKeyMini()))
            continue;

          if (caller is CallerMini) {
            final returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
            if (caller.addReturn(returnContext)) {
              for (final waiter in caller.waiters) {
                _triggerReturn(
                  caller,
                  waiter.$1,
                  waiter.$2,
                  waiter.$3,
                  waiter.$4,
                  returnContext,
                  source: (state.id, position, caller),
                  action: action,
                  callSite: waiter.$5,
                );
              }
            }
          }
        case AcceptAction():
          _acceptedContexts.add((state, frame.context));
      }
    }
  }

  void _triggerReturn(
    CallerMini caller,
    CallerKeyMini? parent,
    State nextState,
    int? minPrecedence,
    ContextMini parentContext,
    ContextMini returnContext, {
    ParseNodeKeyMini? source,
    StateAction? action,
    ParseNodeKeyMini? callSite,
  }) {
    if (minPrecedence != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrecedence) {
      return;
    }
    final nextMarks = markManager
        .branched([parentContext.marks])
        .addList(markManager, returnContext.marks);

    final nextContext = ContextMini(
      parent ?? const RootCallerKeyMini(),
      nextMarks,
      predicateStack: parentContext.predicateStack,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
      tokenHistory: parentContext.tokenHistory,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );
    _enqueue(nextState, nextContext, source: source, action: action, callSite: callSite);
  }

  void _finalize(FrameMini parentFrame) {
    for (final entry in _nextFrameGroups.entries) {
      final (state, caller, minPrecedence, predicateStack) = entry.key;
      final merged = markManager.branched(entry.value);
      int? callerStartPosition =
          (caller is CallerMini) //
          ? caller.startPos
          : (caller is RootCallerKeyMini ? 0 : null);
      final nextFrame = FrameMini(
        ContextMini(
          caller,
          merged,
          predicateStack: predicateStack,
          callStart: callerStartPosition,
          pivot: position + 1,
          tokenHistory: parser._historyByPosition[position],
          minPrecedenceLevel: minPrecedence,
        ),
      );
      nextFrame.nextStates.add(state);
      if (predicateStack.lastOrNull case PredicateCallerKeyMini predicateKey) {
        final tracker = parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
        tracker?.activeFrames++;
      }

      if (isSupportingAmbiguity) {
        final target = (state.id, position + 1, caller);
        if (_nextPredecessorGroups[entry.key] case var predecessors?) {
          this.predecessors.putIfAbsent(target, () => {}).addAll(predecessors);
        }
      }
      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
    _nextPredecessorGroups.clear();
  }

  void _processFrame(FrameMini frame) {
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeFirst();
      if (context.predicateStack.lastOrNull case PredicateCallerKeyMini predicateKey) {
        final tracker = parser._predicateTrackers[(predicateKey.pattern, predicateKey.startPos)];
        tracker?.activeFrames--;
      }
      final currentMarks = isSupportingAmbiguity
          ? _activeContexts[(
              state,
              context.caller,
              context.minPrecedenceLevel,
              context.predicateStack,
            )]!
          : context.marks;
      _process(
        FrameMini(
          ContextMini(
            context.caller,
            currentMarks,
            predicateStack: context.predicateStack,
            callStart: context.callStart,
            pivot: context.pivot,
            tokenHistory: context.tokenHistory,
            minPrecedenceLevel: context.minPrecedenceLevel,
          ),
        ),
        state,
      );
    }
    _finalize(frame);
  }
}
