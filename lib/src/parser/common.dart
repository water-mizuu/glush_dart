import 'dart:collection';

import 'package:glush/src/representation/bsr.dart';
import 'package:glush/src/core/list.dart';
import 'package:glush/src/core/mark.dart';
import 'package:glush/src/core/patterns.dart';
import 'package:glush/src/parser/state_machine.dart';
import 'package:glush/src/representation/sppf.dart';

import 'interface.dart';


// ---------------------------------------------------------------------------
// Type aliases for complex record types used as keys and internal state
// ---------------------------------------------------------------------------

/// Key for tracking lookahead predicate sub-parses by pattern and start position.
typedef PredicateKey = (PatternSymbol pattern, int startPosition);

/// Key for identifying a unique parsing context at a given position.
/// (state, caller, minimumPrecedence, predicateStack)
/// Used for deduplication and result grouping.
typedef ContextKey = (
  State state,
  CallerKey caller,
  int? minimumPrecedence,
  GlushList<PredicateCallerKey> predicateStack,
);

/// Key for rule call memoization (rule, start position, and precedence constraints).
typedef CallerCacheKey = (Rule rule, int startPosition, int? minPrecedenceLevel);

/// Represents a successful parse result at a specific state and context.
typedef AcceptedContext = (State state, Context context);

/// Identifies a node in the predecessor graph (state, position, and caller context).
typedef ParseNodeKey = (int stateId, int position, Object? caller);

/// Represents an incoming edge in the predecessor graph, used for forest extraction.
typedef PredecessorInfo = (
  ParseNodeKey? source,
  StateAction? action,
  GlushList<Mark> marks,
  ParseNodeKey? callSite,
);

/// Represents a waiting frame at a rule call site, to be resumed upon completion.
typedef WaiterInfo = (
  CallerKey? parent,
  State nextState,
  int? minPrecedence,
  Context parentContext,
  ParseNodeKey callSite,
);

// ---------------------------------------------------------------------------
// Parse result types — sealed hierarchy replaces dynamic return values
// ---------------------------------------------------------------------------

/// Sealed result type returned by [GlushParser.parse].
sealed class ParseOutcome {}

/// Returned when parsing fails.
final class ParseError extends ParseOutcome implements Exception {
  final int position;
  ParseError(this.position);
  @override
  String toString() => 'ParseError at position $position';
}

/// Returned when parsing succeeds (marks-based parse).
final class ParseSuccess extends ParseOutcome {
  final ParserResult result;
  ParseSuccess(this.result);
}

/// Returned when parsing succeeds with an ambiguous forest.
final class ParseAmbiguousForestSuccess extends ParseOutcome {
  final GlushList<Mark> forest;
  ParseAmbiguousForestSuccess(this.forest);
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess extends ParseOutcome {
  final ParseForest forest;
  ParseForestSuccess(this.forest);
  @override
  String toString() => 'ParseForestSuccess(forest=$forest)';
}

// ---------------------------------------------------------------------------

/// Holds the results of a basic [parse] operation.
class ParserResult {
  final List<Mark> _rawMarks;
  ParserResult(this._rawMarks);

  List<Mark> get rawMarks => _rawMarks;

  List<String> get marks {
    final result = <String>[];
    String? currentStringMark;

    for (final mark in _rawMarks) {
      if (mark is NamedMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is StringMark) {
        currentStringMark = (currentStringMark ?? '') + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }

  List<List<Object?>> toList() => _rawMarks.map((m) {
    if (m is NamedMark) return m.toList();
    if (m is StringMark) return m.toList();
    return [];
  }).toList();
}

/// Node in a linked list of tokens, providing shared history for lagging frames.
class TokenNode {
  final int unit;
  TokenNode? next;
  TokenNode(this.unit);
}

/// Tracks the status of a lookahead sub-parse (AND/NOT predicate).
class PredicateTracker {
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(Context, State)> waiters = [];
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});
}

// ---------------------------------------------------------------------------
// Internal parsing machinery
// ---------------------------------------------------------------------------

/// Strongly typed key to identify a call site in the parsing state machine.
sealed class CallerKey {
  const CallerKey();
}

/// Represents the root call context (top-level parse, not a rule call).
final class RootCallerKey extends CallerKey {
  const RootCallerKey();
  @override
  int get hashCode => 0;
  @override
  bool operator ==(Object other) => other is RootCallerKey;
}

/// Caller key for a lookahead predicate sub-parse.
final class PredicateCallerKey extends CallerKey {
  final PatternSymbol pattern;
  final int startPosition;
  const PredicateCallerKey(this.pattern, this.startPosition);
  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey &&
      pattern == other.pattern &&
      startPosition == other.startPosition;
  @override
  int get hashCode => Object.hash(pattern, startPosition);
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
final class Caller extends CallerKey {
  final Rule rule;
  final Pattern pattern;
  final int startPosition;
  final int? minPrecedenceLevel;
  final List<WaiterInfo> waiters = [];
  final List<Context> returns = [];

  Caller(this.rule, this.pattern, this.startPosition, this.minPrecedenceLevel);

  bool addWaiter(
    CallerKey? parent,
    State next,
    int? minPrecedence,
    Context callerContext,
    ParseNodeKey node,
  ) {
    for (final (p, n, m, c, _) in waiters) {
      if (p == parent && n == next && m == minPrecedence && c == callerContext) return false;
    }
    waiters.add((parent, next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(Context context) {
    if (returns.contains(context)) return false;
    returns.add(context);
    return true;
  }

  void forEach(void Function(CallerKey?, State, int?, Context, ParseNodeKey) callback) {
    for (final (key, state, minPrecedence, context, node) in waiters) {
      callback(key, state, minPrecedence, context, node);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
class Context {
  final CallerKey caller;
  final GlushList<Mark> marks;
  final GlushList<PredicateCallerKey> predicateStack;
  final int? callStart;
  final int? pivot;
  final TokenNode? tokenHistory;
  final int? minPrecedenceLevel;
  final int? precedenceLevel;

  const Context(
    this.caller,
    this.marks, {
    this.predicateStack = const GlushList.empty(),
    this.callStart,
    this.pivot,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  });

  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    GlushList<PredicateCallerKey>? predicateStack,
    int? callStart,
    int? pivot,
    TokenNode? tokenHistory,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return Context(
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Context &&
          caller == other.caller &&
          marks == other.marks &&
          predicateStack == other.predicateStack &&
          callStart == other.callStart &&
          pivot == other.pivot &&
          tokenHistory == other.tokenHistory &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          precedenceLevel == other.precedenceLevel;

  @override
  int get hashCode => Object.hash(
    caller,
    marks,
    predicateStack,
    callStart,
    pivot,
    tokenHistory,
    minPrecedenceLevel,
    precedenceLevel,
  );
}

/// Set of parsing states to explore from a single context.
class Frame {
  final Context context;
  final Set<State> nextStates;
  Frame(this.context) : nextStates = {};
  Frame copy() => Frame(context);
  CallerKey? get caller => context.caller;
  GlushList<Mark> get marks => context.marks;
}

/// Single parsing step at one input position.
class Step {
  final GlushParser parser;
  final int? token;
  final int position;
  final BsrSet? bsr;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final GlushListManager<Mark> markManager;
  final Map<ParseNodeKey, Set<PredecessorInfo>> predecessors;
  final List<Frame> nextFrames = [];
  final Map<ContextKey, List<GlushList<Mark>>> _nextFrameGroups = {};
  final Map<ContextKey, Set<PredecessorInfo>> _nextPredecessorGroups = {};
  final Map<ContextKey, GlushList<Mark>> _activeContexts = {};
  final Queue<AcceptedContext> _currentWorkList = DoubleLinkedQueue();
  final Map<CallerCacheKey, Caller> _callers = {};
  final Set<CallerKey> _returnedCallers = {};
  final List<AcceptedContext> acceptedContexts = [];
  final List<Frame> requeued = [];

  void requeue(Frame frame) {
    requeued.add(frame);
    if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
      parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]?.activeFrames++;
    }
  }

  Step(
    this.parser,
    this.token,
    this.position, {
    this.bsr,
    required this.markManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    required this.predecessors,
  });

  void _finishPredicate(PredicateTracker tracker, bool matched) {
    if (matched) {
      tracker.matched = true;
      for (final (parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          parser
              .predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]
              ?.activeFrames--;
        }

        if (tracker.isAnd) {
          requeue(Frame(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
    } else if (tracker.activeFrames == 0) {
      for (final (parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          parser
              .predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]
              ?.activeFrames--;
        }

        if (!tracker.isAnd) {
          requeue(Frame(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
    }
  }

  int? _getTokenFor(Frame frame) {
    final framePos = frame.context.pivot ?? 0;
    if (framePos == position) return token;
    return parser.historyByPosition[framePos]?.unit;
  }

  bool get accept => acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    if (acceptedContexts.isEmpty) return [];
    return acceptedContexts[0].$2.marks.toList().cast<Mark>();
  }

  void _enqueue(
    State state,
    Context context, {
    ParseNodeKey? source,
    StateAction? action,
    GlushList<Mark> marks = const GlushList.empty(),
    ParseNodeKey? callSite,
  }) {
    final targetPosition = context.pivot ?? 0;
    if (targetPosition != position) {
      requeue(Frame(context)..nextStates.add(state));
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
      final tracker = parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
      if (tracker != null) {
        tracker.activeFrames++;
      }
    }

    _currentWorkList.add((state, context));
  }

  void _process(Frame frame, State state) {
    for (final action in state.actions) {
      switch (action) {
        case SemanticAction():
          _enqueue(
            action.nextState,
            frame.context.copyWith(
              caller: frame.caller ?? const RootCallerKey(),
              marks: frame.marks,
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
          );
        case TokenAction():
          final token = _getTokenFor(frame);
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            final pattern = action.pattern;
            final shouldCapture =
                captureTokensAsMarks || (pattern is Token && pattern.choice is! ExactToken);

            if (shouldCapture) {
              newMarks = newMarks.add(
                markManager,
                StringMark(String.fromCharCode(token), position),
              );
            }

            if (bsr != null && frame.caller is Caller) {
              final rule = (frame.caller as Caller).rule;
              bsr!.add(rule.symbolId!, frame.context.callStart!, position, position + 1);
            }

            final nextKey = (
              action.nextState,
              frame.caller ?? const RootCallerKey(),
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
            frame.context.copyWith(
              caller: frame.caller ?? const RootCallerKey(),
              marks: frame.marks.add(markManager, mark),
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
            marks: deltaMarks,
          );
        case LabelStartAction():
          final mark = LabelStartMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            frame.context.copyWith(
              caller: frame.caller ?? const RootCallerKey(),
              marks: frame.marks.add(markManager, mark),
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
            marks: deltaMarks,
          );
        case LabelEndAction():
          final mark = LabelEndMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            frame.context.copyWith(
              caller: frame.caller ?? const RootCallerKey(),
              marks: frame.marks.add(markManager, mark),
            ),
            source: (state.id, position, frame.context.caller),
            action: action,
            marks: deltaMarks,
          );
        case PredicateAction():
          final symbol = action.symbol;
          final subParseKey = (symbol, position);
          final isFirst = !parser.predicateTrackers.containsKey(subParseKey);
          final tracker = parser.predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTracker(symbol, position, isAnd: action.isAnd),
          );

          if (tracker.matched) {
            if (tracker.isAnd) {
              requeue(Frame(frame.context)..nextStates.add(action.nextState));
            }
          } else {
            tracker.waiters.add((frame.context, action.nextState));
          }

          final predicateKey = frame.context.predicateStack.lastOrNull;
          if (predicateKey != null) {
            final parentTracker =
                parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
            parentTracker?.activeFrames++;
          }

          if (isFirst && !tracker.matched) {
            final states = parser.stateMachine.ruleFirst[symbol];
            if (states == null) {
              throw StateError('Predicate symbol must resolve to a rule: $symbol');
            }
            final newPredicateKey = PredicateCallerKey(symbol, position);
            final nextStack = GlushListManager<PredicateCallerKey>().push(
              frame.context.predicateStack,
              newPredicateKey,
            );

            for (final firstState in states) {
              _enqueue(
                firstState,
                Context(
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
          final CallerCacheKey key = (action.rule, position, action.minPrecedenceLevel);
          final isNewCaller = !_callers.containsKey(key);
          var caller = _callers[key];
          if (caller == null) {
            caller = _callers[key] = Caller(
              action.rule,
              action.pattern,
              position,
              action.minPrecedenceLevel,
            );
          }
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
                Context(
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
          if (frame.context.minPrecedenceLevel != null &&
              action.precedenceLevel != null &&
              action.precedenceLevel! < frame.context.minPrecedenceLevel!) {
            continue;
          }
          if (_getTokenFor(frame) case var t?
              when action.rule.guard != null && !action.rule.guard!.match(t)) {
            continue;
          }

          final caller = frame.caller;
          final callStart =
              frame.context.callStart ?? (caller is Caller ? caller.startPosition : null);
          if (bsr != null && callStart != null) {
            bsr!.add(action.rule.symbolId!, callStart, frame.context.pivot ?? callStart, position);
          }

          if (caller is PredicateCallerKey) {
            final tracker = parser.predicateTrackers[(caller.pattern, caller.startPosition)];
            if (tracker != null) {
              _finishPredicate(tracker, true);
            }
            continue;
          }

          if (bsr != null && caller is Caller) {
            caller.forEach((parent, state, minimumPrecedence, context, node) {
              if (parent is Caller) {
                bsr!.add(parent.rule.symbolId!, context.callStart!, caller.startPosition, position);
              }
            });
          }

          if (!isSupportingAmbiguity && !_returnedCallers.add(caller ?? const RootCallerKey())) {
            continue;
          }

          if (caller is Caller) {
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
          acceptedContexts.add((state, frame.context));
      }
    }
  }

  void _triggerReturn(
    Caller caller,
    CallerKey? parent,
    State nextState,
    int? minPrecedence,
    Context parentContext,
    Context returnContext, {
    ParseNodeKey? source,
    StateAction? action,
    ParseNodeKey? callSite,
  }) {
    if (minPrecedence != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrecedence) {
      return;
    }
    final nextMarks = markManager
        .branched([parentContext.marks])
        .addList(markManager, returnContext.marks);

    final nextContext = Context(
      parent ?? const RootCallerKey(),
      nextMarks,
      predicateStack: parentContext.predicateStack,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
      tokenHistory: parentContext.tokenHistory,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );
    if (bsr != null && parent is Caller) {
      bsr!.add(
        parent.rule.symbolId!,
        parentContext.callStart!,
        caller.startPosition,
        returnContext.pivot ?? position,
      );
    }

    _enqueue(nextState, nextContext, source: source, action: action, callSite: callSite);
  }

  void finalize() {
    _nextFrameGroups.forEach((key, marksGroup) {
      final (state, caller, minPrecedenceLevel, predicateStack) = key;
      final branchedMarks = markManager.branched(marksGroup);
      final callerStartPosition = (caller is Caller)
          ? caller.startPosition
          : (caller is RootCallerKey ? 0 : null);
      final nextFrame = Frame(
        Context(
          caller,
          branchedMarks,
          predicateStack: predicateStack,
          callStart: callerStartPosition,
          pivot: position + 1,
          tokenHistory: parser.historyByPosition[position],
          minPrecedenceLevel: minPrecedenceLevel,
        ),
      );
      nextFrame.nextStates.add(state);
      if (predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        final tracker =
            parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
        tracker?.activeFrames++;
      }

      if (isSupportingAmbiguity) {
        final target = (state.id, position + 1, caller);
        if (_nextPredecessorGroups[key] case var preds?) {
          predecessors.putIfAbsent(target, () => {}).addAll(preds);
        }
      }
      nextFrames.add(nextFrame);
    });
    _nextFrameGroups.clear();
    _nextPredecessorGroups.clear();
  }

  void processFrame(Frame frame) {
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeFirst();
      if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        final tracker =
            parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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
      _process(Frame(context.copyWith(marks: currentMarks)), state);
    }
    // _finalize will be called by processTokenInternal after all frames are done
  }
}

mixin ParserCore on GlushParserBase {
  TokenNode? historyTail;

  void enqueueFramesForPositionInternal(
    SplayTreeMap<int, List<Frame>> workQueue,
    List<Frame> frames,
  ) {
    for (final frame in frames) {
      final position = frame.context.pivot ?? 0;
      workQueue.putIfAbsent(position, () => []).add(frame);
    }
  }

  void checkExhaustedPredicatesInternal(
    SplayTreeMap<int, List<Frame>> workQueue,
    int currentPosition,
  ) {
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

  Step processTokenInternal(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    required Map<ParseNodeKey, Set<PredecessorInfo>> predecessors,
  }) {
    if (token != null) {
      final node = TokenNode(token);
      if (historyTail == null) {
        historyTail = node;
      } else {
        historyTail!.next = node;
        historyTail = node;
      }
      historyByPosition[currentPosition] = node;
    }

    if (historyTail != null) {
      historyByPosition[currentPosition] = historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    enqueueFramesForPositionInternal(workQueue, frames);

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
          bsr: bsr,
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
      currentStep.finalize();

      if (workQueue.isEmpty || workQueue.firstKey()! > currentPosition) {
        checkExhaustedPredicatesInternal(workQueue, currentPosition);
      }

      if (position < currentPosition) {
        enqueueFramesForPositionInternal(workQueue, currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }

      enqueueFramesForPositionInternal(workQueue, currentStep.requeued);
      currentStep.requeued.clear();
    }

    return stepsAtPosition[currentPosition] ??
        (Step(
          this,
          token,
          currentPosition,
          bsr: bsr,
          markManager: markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        )..finalize());
  }

  GlushList<Mark> extractForestFromGraphInternal(
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
        final ruleForest = extractForestFromGraphInternal(
          source!,
          memo,
          predecessors,
          currentVisiting,
        );
        final parentForest = callSite != null
            ? extractForestFromGraphInternal(callSite, memo, predecessors, currentVisiting)
            : const GlushList<Mark>.empty();

        alternatives.add(parentForest.addList(markManager, ruleForest));
      } else if (source != null) {
        final base = extractForestFromGraphInternal(source, memo, predecessors, currentVisiting);
        alternatives.add(base.addList(markManager, marks));
      } else {
        alternatives.add(marks);
      }
    }
    currentVisiting.remove(node);

    return memo[node] = markManager.branched(alternatives);
  }


}
