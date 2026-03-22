import 'dart:collection';

import 'package:glush/src/grammar.dart';
import 'package:glush/src/list.dart';
import 'package:glush/src/mark.dart';
import 'package:glush/src/patterns.dart';
import 'package:glush/src/state_machine.dart';

/// Minimal version of [SMParser] that only supports recognize, parse, and parseAmbiguous.
/// No BSR, no SPPF, only Mark related results.
/// Includes support for nested predicates.
class SMParserMini {
  final StateMachine stateMachine;
  late final List<FrameMini> _initialFrames;
  final GlushListManager<Mark> _markManager = GlushListManager<Mark>();
  final GlushListManager<PredicateCallerKeyMini> _predicateStackManager =
      GlushListManager<PredicateCallerKeyMini>();
  final Map<int, TokenNodeMini> _historyByPosition = {};
  TokenNodeMini? _historyTail;
  final Map<(PatternSymbol, int), PredicateTrackerMini> _predicateTrackers = {};


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
    const initialContext = ContextMini(
      RootCallerKeyMini(),
      GlushList.empty(),
      predicateStack: GlushList.empty(),
    );
    final initialFrame = FrameMini(initialContext);
    initialFrame.nextStates.addAll(stateMachine.initialStates);
    _initialFrames = [initialFrame];
  }


  bool recognize(String input) {
    var frames = _initialFrames;
    int position = 0;

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

  ParseOutcomeMini parse(String input) {
    var frames = _initialFrames;
    int position = 0;

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

  ParseOutcomeMini parseAmbiguous(String input, {bool? captureTokensAsMarks}) {
    final Map<_ParseNode, Set<_Predecessor>> predecessors = {};
    var frames = _initialFrames;
    int position = 0;

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
      if (frames.isEmpty) return ParseErrorMini(position);
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
      final memo = <_ParseNode, GlushList<Mark>>{};
      final results = <GlushList<Mark>>[];

      for (final (state, ctx) in lastStep._acceptedContexts) {
        final rootNode = (state.id, position, ctx.caller);
        results.add(_extractForestFromGraph(rootNode, memo, predecessors));
      }

      return ParseAmbiguousForestSuccessMini(_markManager.branched(results));
    } else {
      return ParseErrorMini(position);
    }
  }

  GlushList<Mark> _extractForestFromGraph(
    _ParseNode node,
    Map<_ParseNode, GlushList<Mark>> memo,
    Map<_ParseNode, Set<_Predecessor>> predecessors, [
    Set<_ParseNode>? visiting,
  ]) {
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <_ParseNode>{};
    if (currentVisiting.contains(node)) {
      return const GlushList<Mark>.empty();
    }

    currentVisiting.add(node);
    final preds = predecessors[node];
    if (preds == null) return memo[node] = const GlushList<Mark>.empty();

    final alts = <GlushList<Mark>>[];
    try {
      for (final (source, action, marks, callSite) in preds) {
        if (action is ReturnAction) {
          final ruleForest = _extractForestFromGraph(source!, memo, predecessors, currentVisiting);
          final parentForest = callSite != null
              ? _extractForestFromGraph(callSite, memo, predecessors, currentVisiting)
              : const GlushList<Mark>.empty();
          alts.add(parentForest.addList(_markManager, ruleForest));
        } else if (source != null) {
          final base = _extractForestFromGraph(source, memo, predecessors, currentVisiting);
          alts.add(base.addList(_markManager, marks));
        } else {
          alts.add(marks);
        }
      }
    } finally {
      currentVisiting.remove(node);
    }

    return memo[node] = _markManager.branched(alts);
  }

  StepMini _processToken(
    int? token,
    int position,
    List<FrameMini> frames, {
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    required Map<_ParseNode, Set<_Predecessor>> predecessors,
  }) {
    if (token != null) {
      final node = TokenNodeMini(token);
      if (_historyTail == null) {
        _historyTail = node;
      } else {
        _historyTail!.next = node;
        _historyTail = node;
      }
      _historyByPosition[position] = node;
    }

    if (_historyTail != null) {
      _historyByPosition[position] = _historyTail!;
    }

    final stepsAtPosition = <int, StepMini>{};
    final workQueue = SplayTreeMap<int, List<FrameMini>>((a, b) => a.compareTo(b));

    void addFramesToQueue(List<FrameMini> newFrames) {
      for (final f in newFrames) {
        final pos = f.context.pivot ?? 0;
        workQueue.putIfAbsent(pos, () => []).add(f);

        if (f.context.predicateStack.lastOrNull case var pk?) {
          _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames++;
        }
      }
    }

    addFramesToQueue(frames);

    while (workQueue.isNotEmpty) {
      final pos = workQueue.firstKey()!;
      if (pos > position) break;

      final posFrames = workQueue.remove(pos)!;

      final currentStep = stepsAtPosition.putIfAbsent(pos, () {
        final posToken = (pos == position) ? token : _historyByPosition[pos]?.unit;
        return StepMini(
          this,
          posToken,
          pos,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          requeue: addFramesToQueue,
          predecessors: predecessors,
        );
      });

      for (final f in posFrames) {
        if (f.context.predicateStack.lastOrNull case var pk?) {
          _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames--;
        }
        currentStep._processFrame(f);
      }

      if (workQueue.isEmpty || workQueue.firstKey()! > position) {
        _checkExhaustedPredicates(workQueue, position);
      }

      if (pos < position) {
        for (final f in currentStep.nextFrames) {
          if (f.context.predicateStack.lastOrNull case var pk?) {
            _predicateTrackers[(pk.pattern, pk.startPos)]?.activeFrames--;
          }
        }
        addFramesToQueue(currentStep.nextFrames);
        currentStep.nextFrames.clear();
      }
    }

    return stepsAtPosition[position] ??
        StepMini(
          this,
          token,
          position,
          markManager: _markManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          requeue: addFramesToQueue,
          predecessors: predecessors,
        );
  }

  void _checkExhaustedPredicates(SplayTreeMap<int, List<FrameMini>> workQueue, int currentPosition) {
    bool changed = true;
    while (changed) {
      changed = false;
      final toRemove = <(PatternSymbol, int)>{};
      for (final entry in _predicateTrackers.entries) {
        final tracker = entry.value;

        if (tracker.activeFrames == 0 && !tracker.matched) {
          for (final (parentCtx, nextState) in tracker.waiters) {
            final pk = parentCtx.predicateStack.lastOrNull;
            if (pk != null) {
              final parentTracker = _predicateTrackers[(pk.pattern, pk.startPos)];
              if (parentTracker != null) {
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPos = parentCtx.pivot ?? 0;
              workQueue
                  .putIfAbsent(targetPos, () => [])
                  .add(FrameMini(parentCtx)..nextStates.add(nextState));

              if (parentCtx.predicateStack.lastOrNull case var ppk?) {
                _predicateTrackers[(ppk.pattern, ppk.startPos)]?.activeFrames++;
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

  List<List<Object?>> toList() => _rawMarks.map((m) {
    if (m is NamedMark) return m.toList();
    if (m is StringMark) return m.toList();
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

final class CallerMini extends CallerKeyMini {
  final Rule rule;
  final Pattern pattern;
  final int startPos;
  final int? minPrecedenceLevel;
  final List<(CallerKeyMini?, State, int?, ContextMini, _ParseNode)> waiters = [];
  final List<ContextMini> returns = [];

  CallerMini(this.rule, this.pattern, this.startPos, this.minPrecedenceLevel);

  bool addWaiter(CallerKeyMini? parent, State next, int? minPrec, ContextMini cctx, _ParseNode node) {
    for (final w in waiters) {
      if (w.$1 == parent && w.$2 == next && w.$3 == minPrec && w.$4 == cctx) return false;
    }
    waiters.add((parent, next, minPrec, cctx, node));
    return true;
  }

  bool addReturn(ContextMini ctx) {
    if (returns.contains(ctx)) return false;
    returns.add(ctx);
    return true;
  }

  void forEach(void Function(CallerKeyMini?, State, int?, ContextMini, _ParseNode) callback) {
    for (final (key, state, minPrec, ctx, node) in waiters) {
      callback(key, state, minPrec, ctx, node);
    }
  }
}

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

typedef _ParseNode = (int stateId, int pos, Object? caller);
typedef _Predecessor = (
  _ParseNode? source,
  StateAction? action,
  GlushList<Mark> marks,
  _ParseNode? callSite,
);

class StepMini {
  final SMParserMini parser;
  final int? token;
  final int position;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final GlushListManager<Mark> markManager;
  final Map<_ParseNode, Set<_Predecessor>> predecessors;
  final List<FrameMini> nextFrames = [];
  final Map<(State, CallerKeyMini, int?, GlushList<PredicateCallerKeyMini>), List<GlushList<Mark>>>
  _nextFrameGroups = {};
  final Map<(State, CallerKeyMini, int?, GlushList<PredicateCallerKeyMini>), Set<_Predecessor>>
  _nextPredecessorGroups = {};
  final Map<(State, CallerKeyMini, int?, GlushList<PredicateCallerKeyMini>), GlushList<Mark>>
  _activeContexts = {};
  final Queue<(State, ContextMini)> _currentWorkList = DoubleLinkedQueue();
  final Map<(Rule, int, int?), CallerMini> _callers = {};
  final Set<CallerKeyMini> _returnedCallers = {};
  final List<(State, ContextMini)> _acceptedContexts = [];
  final void Function(List<FrameMini>) requeue;

  StepMini(
    this.parser,
    this.token,
    this.position, {
    required this.markManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    required this.requeue,
    required this.predecessors,
  });

  void _finishPredicate(PredicateTrackerMini tracker, bool matched) {
    if (matched) {
      tracker.matched = true;
      for (final (parentCtx, nextState) in tracker.waiters) {
        final pk = parentCtx.predicateStack.lastOrNull;
        if (pk != null) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (tracker.isAnd) {
          requeue([FrameMini(parentCtx)..nextStates.add(nextState)]);
        }
      }
      tracker.waiters.clear();
    } else if (tracker.activeFrames == 0) {
      for (final (parentCtx, nextState) in tracker.waiters) {
        final pk = parentCtx.predicateStack.lastOrNull;
        if (pk != null) {
          final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
          parentTracker?.activeFrames--;
        }

        if (!tracker.isAnd) {
          requeue([FrameMini(parentCtx)..nextStates.add(nextState)]);
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

  void _enqueue(
    State state,
    ContextMini context, {
    _ParseNode? source,
    StateAction? action,
    GlushList<Mark> marks = const GlushList.empty(),
    _ParseNode? callSite,
  }) {
    final targetPos = context.pivot ?? 0;
    if (targetPos != position) {
      requeue([FrameMini(context)..nextStates.add(state)]);
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

    final pk = context.predicateStack.lastOrNull;
    if (pk != null) {
      final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
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
          final symbol = action.symbol;
          final subParseKey = (symbol, position);
          final isFirst = !parser._predicateTrackers.containsKey(subParseKey);
          final tracker = parser._predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTrackerMini(symbol, position, isAnd: action.isAnd),
          );

          if (tracker.matched) {
            if (tracker.isAnd) {
              requeue([FrameMini(frame.context)..nextStates.add(action.nextState)]);
            }
          } else {
            tracker.waiters.add((frame.context, action.nextState));
          }

          final pk = frame.context.predicateStack.lastOrNull;
          if (pk != null) {
            final parentTracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
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
            for (final fs in states) {
              _enqueue(
                fs,
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
            for (final rctx in caller.returns) {
              _triggerReturn(
                caller,
                frame.caller,
                action.returnState,
                action.minPrecedenceLevel,
                frame.context,
                rctx,
                source: (state.id, position, caller),
                action: action,
                callSite: (state.id, position, frame.context.caller),
              );
            }
          }
        case ReturnAction():
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
    _ParseNode? source,
    StateAction? action,
    _ParseNode? callSite,
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
      final (state, caller, minP, pStack) = entry.key;
      final merged = markManager.branched(entry.value);
      int? nCS = (caller is CallerMini) ? caller.startPos : (caller is RootCallerKeyMini ? 0 : null);
      final nextFrame = FrameMini(
        ContextMini(
          caller,
          merged,
          predicateStack: pStack,
          callStart: nCS,
          pivot: position + 1,
          tokenHistory: parser._historyByPosition[position],
          minPrecedenceLevel: minP,
        ),
      );
      nextFrame.nextStates.add(state);
      if (pStack.lastOrNull case PredicateCallerKeyMini pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
        tracker?.activeFrames++;
      }

      if (isSupportingAmbiguity) {
        final target = (state.id, position + 1, caller);
        if (_nextPredecessorGroups[entry.key] case var preds?)
          predecessors.putIfAbsent(target, () => {}).addAll(preds);
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
      if (context.predicateStack.lastOrNull case PredicateCallerKeyMini pk) {
        final tracker = parser._predicateTrackers[(pk.pattern, pk.startPos)];
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

