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
  GlushList<DerivationKey> derivationPath,
);

/// Key for rule call memoization (rule, start position, and precedence constraints).
typedef CallerCacheKey = (Rule rule, int startPosition, int? minPrecedenceLevel);

/// Represents a successful parse result at a specific state and context.
typedef AcceptedContext = (State state, Context context);

/// Identifies a parser continuation point by state, position, and caller context.
typedef ParseNodeKey = (int stateId, int position, Object? caller);

/// Returns true when a mark stream has balanced label start/end markers.
bool hasBalancedLabelMarks(Iterable<Mark> marks) {
  final stack = <String>[];
  for (final mark in marks) {
    switch (mark) {
      case LabelStartMark(:var name):
        stack.add(name);
      case LabelEndMark(:var name):
        if (stack.isEmpty || stack.last != name) {
          return false;
        }
        stack.removeLast();
      case NamedMark():
      case StringMark():
        break;
    }
  }
  return stack.isEmpty;
}

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
    StringBuffer? currentStringMark;

    for (final mark in _rawMarks) {
      // Dispatch by mark kind to rebuild a human-readable flattened stream.
      if (mark is NamedMark) {
        // Named marks break string runs, so flush buffered token text first.
        if (currentStringMark != null) {
          result.add(currentStringMark.toString());
          currentStringMark = null;
        }
        result.add(mark.name);
        // Label starts are emitted as their own marker entries.
      } else if (mark is LabelStartMark) {
        // Label boundaries also break string runs for stable mark segmentation.
        if (currentStringMark != null) {
          result.add(currentStringMark.toString());
          currentStringMark = null;
        }
        result.add(mark.name);
        // Raw token text contributes to the currently buffered string chunk.
      } else if (mark is StringMark) {
        // Adjacent token chars are merged into one logical text chunk.
        currentStringMark ??= StringBuffer();
        currentStringMark.write(mark.value);
      }
    }
    // Flush trailing string chunk, if any.
    if (currentStringMark != null) {
      // Flush trailing buffered text after the loop ends.
      result.add(currentStringMark.toString());
    }

    return result;
  }

  List<List<Object?>> toList() => _rawMarks.map((m) => m.toList()).toList();
}

/// Node in a linked list of tokens, providing shared history for lagging frames.
class TokenNode {
  final int unit;
  TokenNode? next;
  TokenNode(this.unit);
}

/// Tracks one lookahead sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same predicate from multiple branches, so the
/// tracker counts how many predicate-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the predicate as matched
/// or exhausted, and then wake any parked continuations.
class PredicateTracker {
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(ParseNodeKey? source, Context, State)> waiters = [];
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});

  /// Mark one predicate-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one predicate-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      'PredicateTracker underflow: removePendingFrame() called with no pending frames.',
    );
    activeFrames--;
  }

  /// True when the predicate can no longer succeed and has not matched.
  bool get canResolveFalse => !matched && activeFrames == 0;
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
  final Set<(CallerKey?, State, int?, Context)> _waiterKeys = {};
  final Set<Context> _returnSet = {};

  Caller(this.rule, this.pattern, this.startPosition, this.minPrecedenceLevel);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Caller &&
          runtimeType == other.runtimeType &&
          rule == other.rule &&
          pattern == other.pattern &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel;

  @override
  int get hashCode => Object.hash(rule, pattern, startPosition, minPrecedenceLevel);

  bool addWaiter(
    CallerKey? parent,
    State next,
    int? minPrecedence,
    Context callerContext,
    ParseNodeKey node,
  ) {
    final waiterKey = (parent, next, minPrecedence, callerContext);
    if (!_waiterKeys.add(waiterKey)) return false;
    waiters.add((parent, next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(Context context) {
    if (!_returnSet.add(context)) return false;
    returns.add(context);
    return true;
  }

  Iterable<(CallerKey?, Context)> iterate() sync* {
    for (final (key, _, _, context, _) in waiters) {
      yield (key, context);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
class Context {
  final CallerKey caller;
  final GlushList<Mark> marks;
  final GlushList<DerivationKey> derivationPath;
  final GlushList<PredicateCallerKey> predicateStack;
  final PatternSymbol? bsrRuleSymbol;
  final int? callStart;
  final int? pivot;
  final TokenNode? tokenHistory;
  final int? minPrecedenceLevel;
  final int? precedenceLevel;

  const Context(
    this.caller,
    this.marks, {
    this.derivationPath = const GlushList.empty(),
    this.predicateStack = const GlushList.empty(),
    this.bsrRuleSymbol,
    this.callStart,
    this.pivot,
    this.tokenHistory,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  });

  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    GlushList<DerivationKey>? derivationPath,
    GlushList<PredicateCallerKey>? predicateStack,
    PatternSymbol? bsrRuleSymbol,
    int? callStart,
    int? pivot,
    TokenNode? tokenHistory,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    return Context(
      caller ?? this.caller,
      marks ?? this.marks,
      derivationPath: derivationPath ?? this.derivationPath,
      predicateStack: predicateStack ?? this.predicateStack,
      bsrRuleSymbol: bsrRuleSymbol ?? this.bsrRuleSymbol,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
      tokenHistory: tokenHistory ?? this.tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel ?? this.minPrecedenceLevel,
      precedenceLevel: precedenceLevel ?? this.precedenceLevel,
    );
  }

  Context withMarks(GlushList<Mark> nextMarks) {
    if (identical(nextMarks, marks)) return this;
    return Context(
      caller,
      nextMarks,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      tokenHistory: tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  Context withCaller(CallerKey nextCaller) {
    if (identical(nextCaller, caller)) return this;
    return Context(
      nextCaller,
      marks,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      tokenHistory: tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  Context withCallerAndMarks(CallerKey nextCaller, GlushList<Mark> nextMarks) {
    if (identical(nextCaller, caller) && identical(nextMarks, marks)) return this;
    return Context(
      nextCaller,
      nextMarks,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
      tokenHistory: tokenHistory,
      minPrecedenceLevel: minPrecedenceLevel,
      precedenceLevel: precedenceLevel,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Context &&
          caller == other.caller &&
          marks == other.marks &&
          derivationPath == other.derivationPath &&
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
    derivationPath,
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
  final bool replay;
  Frame(this.context, {this.replay = false}) : nextStates = {};
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
  final GlushListManager<DerivationKey> derivationManager;
  final List<Frame> nextFrames = [];
  final Map<ContextKey, List<GlushList<Mark>>> _nextFrameGroups = {};
  final Map<ContextKey, Set<GlushList<Mark>>> _activeContexts = {};
  final Queue<AcceptedContext> _currentWorkList = DoubleLinkedQueue();
  final Map<CallerCacheKey, Caller> _callers;
  final Set<CallerKey> _returnedCallers = {};
  final Set<AcceptedContext> _acceptedContextSet = {};
  final List<AcceptedContext> acceptedContexts = [];
  final List<Frame> requeued = [];

  /// Requeue work that targets a different pivot position.
  ///
  /// This keeps parsing position-ordered: same-position closure is completed
  /// before processing another pivot.
  ///
  /// If the frame belongs to a predicate stack, we increase `activeFrames`
  /// because the predicate still has pending work.
  void requeue(Frame frame) {
    requeued.add(frame);
    // Only predicate-owned frames affect predicate liveness counters.
    if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
      assert(
        !frame.context.predicateStack.isEmpty,
        'Invariant violation in requeue: predicate stack lookup implies non-empty stack.',
      );
      // A requeued predicate frame is still live work for that tracker.
      parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]
          ?.addPendingFrame();
    }
  }

  Step(
    this.parser,
    this.token,
    this.position, {
    this.bsr,
    required this.markManager,
    required this.derivationManager,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
  }) : _callers = parser.callers;

  /// Resolve a predicate sub-parse and wake any parked continuations.
  ///
  /// Rules:
  /// - AND predicate (`&`) continues only when matched.
  /// - NOT predicate (`!`) continues only when exhausted without match.
  ///
  /// Nested predicates bubble completion back to their parent tracker so the
  /// parent only resolves after every child branch is done.
  void _finishPredicate(PredicateTracker tracker, bool matched) {
    // A successful predicate can release all AND waiters immediately.
    if (matched) {
      tracker.matched = true;
      for (final (source, parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          final parentTracker =
              parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (parentTracker != null) {
            // This child branch is no longer pending in the parent predicate.
            parentTracker.removePendingFrame();
          }
        }

        // AND predicates resume only on success.
        if (tracker.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: parentContext,
            nextState: nextState,
            isAnd: tracker.isAnd,
            symbol: tracker.symbol,
          );
        }
      }
      tracker.waiters.clear();
    } else if (tracker.canResolveFalse) {
      // The predicate exhausted without matching, so only NOT waiters resume.
      for (final (source, parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          final parentTracker =
              parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (parentTracker != null) {
            // This child branch is no longer pending in the parent predicate.
            parentTracker.removePendingFrame();
          }
        }

        // NOT predicates resume only after the child failed to match.
        if (!tracker.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: parentContext,
            nextState: nextState,
            isAnd: tracker.isAnd,
            symbol: tracker.symbol,
          );
        }
      }
      tracker.waiters.clear();
    }
  }

  /// Resume a continuation that was parked behind a predicate.
  ///
  /// The frame is requeued at the original parent pivot so it can catch up
  /// through already-seen input using the parser's token history, just like an
  /// epsilon transition reopening a delayed path.
  void _resumeLaggedPredicateContinuation({
    required ParseNodeKey? source,
    required Context parentContext,
    required State nextState,
    required bool isAnd,
    required PatternSymbol symbol,
    Object? branchKey,
  }) {
    var nextContext = parentContext;
    if (isSupportingAmbiguity && source != null) {
      final nextBranchKey =
          branchKey ?? PredicateAction(isAnd: isAnd, symbol: symbol, nextState: nextState);
      final nextPath = derivationManager.push(parentContext.derivationPath, (
        source,
        nextBranchKey,
        null,
      ));
      nextContext = parentContext.copyWith(derivationPath: nextPath);
    }

    requeue(Frame(nextContext)..nextStates.add(nextState));
  }

  /// Seed a predicate sub-parse at the current input position.
  ///
  /// Predicates are lookahead-only, so their entry states are spawned in a
  /// separate sub-parse that can resolve later and wake parked continuations.
  void _spawnPredicateSubparse(PatternSymbol symbol, Frame frame) {
    final states = parser.stateMachine.ruleFirst[symbol];
    // Missing entry states indicates invalid predicate target symbol.
    if (states == null) {
      // Predicates must map to rule entries in the state machine.
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
          bsrRuleSymbol: null,
          callStart: position,
          pivot: position,
          tokenHistory: frame.context.tokenHistory,
        ),
      );
    }
  }

  int? _getTokenFor(Frame frame) {
    final framePos = frame.context.pivot ?? 0;
    // Frame already at this step's pivot: use current token directly.
    if (framePos == position) return token;
    // Otherwise pull token from shared history at the frame's pivot.
    return parser.historyByPosition[framePos]?.unit;
  }

  bool get accept => acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    // No accept state means no valid mark stream.
    if (acceptedContexts.isEmpty) return [];
    return acceptedContexts[0].$2.marks.toList().cast<Mark>();
  }

  /// Enqueue an active parser configuration for this step.
  ///
  /// Deduplication key is `(state, caller, minPrecedence, predicateStack)`.
  /// In ambiguity mode we still preserve distinct mark branches even when the
  /// target configuration is already active, because marks carry the derivation.
  void _enqueue(
    State state,
    Context context, {
    ParseNodeKey? source,
    StateAction? action,
    Object? branchKey,
    ParseNodeKey? callSite,
  }) {
    var nextContext = context;
    if (isSupportingAmbiguity && source != null) {
      final nextBranchKey = branchKey ?? action ?? state;
      final nextPath = derivationManager.push(context.derivationPath, (
        source,
        nextBranchKey,
        callSite,
      ));
      nextContext = context.copyWith(derivationPath: nextPath);
    }

    final targetPosition = nextContext.pivot ?? 0;
    // Queue cross-position work instead of mixing pivots in this step.
    if (targetPosition != position) {
      // Cross-position work is deferred to preserve position-order semantics.
      requeue(Frame(nextContext)..nextStates.add(state));
      return;
    }

    final key = (
      state,
      nextContext.caller,
      nextContext.minPrecedenceLevel,
      nextContext.predicateStack,
      nextContext.derivationPath,
    );
    // Forest mode tracks alternate derivation edges for equivalent contexts.
    if (isSupportingAmbiguity) {
      // Forest mode keeps alternate derivation edges even when a context is
      // already active. Track each distinct mark branch independently so we
      // do not blend unrelated label paths together.
      final branches = _activeContexts.putIfAbsent(key, () => <GlushList<Mark>>{});
      if (!branches.add(nextContext.marks)) {
        return;
      }
    } else {
      // In non-forest mode, keep only the first equivalent context.
      if (_activeContexts.containsKey(key)) return;
      _activeContexts[key] = {nextContext.marks};
    }

    final predicateKey = nextContext.predicateStack.lastOrNull;
    // Predicate-owned frames keep the tracker alive until they are processed.
    if (predicateKey != null) {
      final tracker = parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
      if (tracker != null) {
        tracker.addPendingFrame();
      }
    }

    _currentWorkList.add((state, nextContext));
  }

  /// Execute outgoing actions for one `(frame,state)` pair.
  ///
  /// Token-consuming actions are batched into `_nextFrameGroups` and finalized
  /// together in [finalize], while zero-width actions are enqueued immediately.
  /// This split avoids interleaving same-position closure with next-position work.
  void _process(Frame frame, State state) {
    final frameContext = frame.context;
    for (final action in state.actions) {
      final source = (state.id, position, frameContext.caller);
      final callerOrRoot = frame.caller ?? const RootCallerKey();
      switch (action) {
        case TokenAction():
          final token = _getTokenFor(frame);
          // Token actions fire only when a token exists and matches the pattern.
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            final terminalSymbol = action.pattern.symbolId;
            final pattern = action.pattern;
            final shouldCapture =
                captureTokensAsMarks || (pattern is Token && pattern.choice is! ExactToken);

            if (terminalSymbol != null) {
              bsr?.addTerminal(terminalSymbol, position, position + 1, token);
            }

            // Capture policy controls whether consumed chars become StringMarks.
            if (shouldCapture) {
              // Emit consumed character as mark for downstream reconstruction.
              newMarks = newMarks.add(
                markManager,
                StringMark(String.fromCharCode(token), position),
              );
            }

            if (frame.context.bsrRuleSymbol != null && frame.context.callStart != null) {
              bsr?.add(
                frame.context.bsrRuleSymbol!,
                frame.context.callStart!,
                position,
                position + 1,
              );
            }

            // Batched until finalize() so token-consuming transitions advance
            // together from this position to the next pivot.
            final nextKey = (
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
              frameContext.derivationPath,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
          }
        case MarkAction():
          final mark = NamedMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
            action: action,
          );
        case LabelStartAction():
          final mark = LabelStartMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
            action: action,
            callSite: null,
          );
          break;
        case LabelEndAction():
          final mark = LabelEndMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
            action: action,
          );
          break;
        case PredicateAction():
          final symbol = action.symbol;
          final subParseKey = (symbol, position);
          final isFirst = !parser.predicateTrackers.containsKey(subParseKey);
          final tracker = parser.predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTracker(symbol, position, isAnd: action.isAnd),
          );
          assert(
            tracker.symbol == symbol && tracker.startPosition == position,
            'Invariant violation in PredicateAction: tracker key and payload diverged.',
          );
          assert(
            tracker.isAnd == action.isAnd,
            'Invariant violation in PredicateAction: mixed AND/NOT trackers share '
            'the same (symbol,position) key.',
          );

          // A predicate may be re-entered after it has already matched.
          if (tracker.matched) {
            // AND can continue immediately; NOT must stop.
            if (tracker.isAnd) {
              _resumeLaggedPredicateContinuation(
                source: source,
                parentContext: frame.context,
                nextState: action.nextState,
                isAnd: action.isAnd,
                symbol: action.symbol,
                branchKey: action,
              );
            }
            // The predicate is already known to have failed.
          } else if (!isFirst && tracker.canResolveFalse) {
            if (!tracker.isAnd) {
              _resumeLaggedPredicateContinuation(
                source: source,
                parentContext: frame.context,
                nextState: action.nextState,
                isAnd: action.isAnd,
                symbol: action.symbol,
                branchKey: action,
              );
            }
          } else {
            // The result is unknown, so park this continuation until the
            // predicate resolves.
            tracker.waiters.add((source, frameContext, action.nextState));

            final predicateKey = frameContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              final parentTracker =
                  parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              // The parent cannot settle until this child branch completes.
              parentTracker?.addPendingFrame();
            }
          }
          // Spawn the sub-parse only the first time this predicate is seen here.
          if (isFirst && !tracker.matched) {
            _spawnPredicateSubparse(symbol, frame);
          }

        case CallAction():
          final CallerCacheKey key = (action.rule, position, action.minPrecedenceLevel);
          final isNewCaller = !_callers.containsKey(key);
          var caller = _callers[key];
          assert(
            isNewCaller == (caller == null),
            'Invariant violation in CallAction: caller cache containsKey/get mismatch.',
          );
          // Create caller node if no memoized node exists for this key yet.
          if (caller == null) {
            // Create shared caller node once; later calls reuse it.
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
          // New caller needs initial rule-entry seeding.
          if (isNewCaller) {
            // First time this caller key appears: seed rule entry states.
            final states = parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
            for (final firstState in states) {
              _enqueue(
                firstState,
                Context(
                  caller,
                  const GlushList.empty(),
                  predicateStack: frame.context.predicateStack,
                  bsrRuleSymbol: action.rule.symbolId!,
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                  minPrecedenceLevel: action.minPrecedenceLevel,
                ),
                source: source,
                action: action,
                callSite: (state.id, position, frame.context.caller),
              );
            }
            // Existing caller with a new waiter replays prior returns.
          } else if (isNewWaiter) {
            // Existing caller + new waiter => replay already-memoized returns.
            // Caller already has completed returns; replay them to this waiter.
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
        case TailCallAction():
          // Tail-call optimized recursion re-enters the rule without allocating
          // a fresh caller node. The enclosing return is unchanged, so the
          // current caller context can be reused as a simple loop back-edge.
          final states = parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
          for (final firstState in states) {
            _enqueue(
              firstState,
              frame.context.copyWith(
                pivot: position,
                tokenHistory: frame.context.tokenHistory,
                minPrecedenceLevel: action.minPrecedenceLevel,
              ),
              source: source,
              action: action,
            );
          }
        case ReturnAction():
          // Enforce call-site precedence gating for this return.
          if (frame.context.minPrecedenceLevel != null &&
              action.precedenceLevel != null &&
              action.precedenceLevel! < frame.context.minPrecedenceLevel!) {
            // Returned precedence is below required minimum for this call-site.
            continue;
          }
          // Enforce optional rule guard against current lookahead token.
          if (_getTokenFor(frame) case var t?
              when action.rule.guard != null && !action.rule.guard!.match(t)) {
            // Guarded return fails against current lookahead token.
            continue;
          }

          final caller = frame.caller;
          final callStart =
              frame.context.callStart ?? //
              (caller is Caller ? caller.startPosition : null);

          if (frame.context.bsrRuleSymbol != null && callStart != null) {
            bsr?.add(
              frame.context.bsrRuleSymbol!,
              callStart,
              frame.context.pivot ?? callStart,
              position,
            );
          }

          // Predicate returns settle the predicate tracker directly.
          if (caller is PredicateCallerKey) {
            assert(
              frame.context.predicateStack.lastOrNull == caller,
              'Invariant violation in ReturnAction: predicate caller should be the top of predicateStack.',
            );
            final tracker = parser.predicateTrackers[(caller.pattern, caller.startPosition)];
            if (tracker == null) {
              // The predicate may already have resolved in this position.
              continue;
            }

            // Success resolves the predicate immediately.
            _finishPredicate(tracker, true);
            continue;
          }

          if (caller is Caller) {
            // Record completion edges for each parent waiter.
            for (final (_, context) in caller.iterate()) {
              if (context.bsrRuleSymbol != null && context.callStart != null) {
                bsr?.add(
                  context.bsrRuleSymbol!,
                  context.callStart!,
                  caller.startPosition,
                  position,
                );
              }
            }
          }

          // In single-derivation mode, replay each caller's returns once.
          if (!isSupportingAmbiguity && !_returnedCallers.add(caller ?? const RootCallerKey())) {
            // Logical meaning:
            // - in single-derivation mode we replay returns once per caller key
            // - if add() is false, this caller was already replayed
            // => skip duplicate resume fan-out.
            continue;
          }

          // Only caller nodes memoize return contexts and wake waiters.
          if (caller is Caller) {
            // Only rule-call callers memoize and replay return contexts.
            final returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
            // Replay to waiters only when this return context is newly added.
            if (caller.addReturn(returnContext)) {
              // Newly discovered return context fan-outs to all queued waiters.
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
          final accepted = (state, frame.context);
          if (_acceptedContextSet.add(accepted)) {
            acceptedContexts.add(accepted);
          }
      }
    }
  }

  /// Resume a call-site waiter with one concrete return context.
  ///
  /// This applies call-site precedence filtering and merges marks as:
  /// `parent marks + returned marks`.
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
    assert(
      parent is! Caller || parentContext.callStart != null,
      'Invariant violation in _triggerReturn: parent Caller requires parentContext.callStart.',
    );
    // Call-site can reject returns below its minimum precedence threshold.
    if (minPrecedence != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrecedence) {
      // Waiter's precedence threshold is not met by this return.
      return;
    }
    // Fast paths for the common case where one/both mark streams are empty.
    // This avoids building branched wrappers for right-recursive call returns.
    final GlushList<Mark> nextMarks;
    if (parentContext.marks.isEmpty) {
      nextMarks = returnContext.marks;
    } else if (returnContext.marks.isEmpty) {
      nextMarks = parentContext.marks;
    } else {
      nextMarks = markManager
          .branched([parentContext.marks])
          .addList(markManager, returnContext.marks);
    }

    final nextContext = Context(
      parent ?? const RootCallerKey(),
      nextMarks,
      derivationPath: parentContext.derivationPath,
      predicateStack: parentContext.predicateStack,
      bsrRuleSymbol: parentContext.bsrRuleSymbol,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
      tokenHistory: parentContext.tokenHistory,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );
    if (parentContext.bsrRuleSymbol != null && parentContext.callStart != null) {
      bsr?.add(
        parentContext.bsrRuleSymbol!,
        parentContext.callStart!,
        caller.startPosition,
        returnContext.pivot ?? position,
      );
    }

    _enqueue(nextState, nextContext, source: source, action: action, callSite: callSite);
  }

  /// Materialize batched token transitions into next-position frames.
  ///
  /// Grouping here preserves deterministic ordering and merges equivalent
  /// contexts with branched marks.
  void finalize() {
    for (final MapEntry(:key, value: marksGroup) in _nextFrameGroups.entries) {
      final (state, caller, minPrecedenceLevel, predicateStack, derivationPath) = key;
      final branchedMarks = markManager.branched(marksGroup);
      final callerStartPosition = (caller is Caller)
          ? caller.startPosition
          : (caller is RootCallerKey ? 0 : null);
      final nextFrame = Frame(
        Context(
          caller,
          branchedMarks,
          derivationPath: derivationPath,
          predicateStack: predicateStack,
          bsrRuleSymbol: caller is Caller ? caller.rule.symbolId! : null,
          callStart: callerStartPosition,
          pivot: position + 1,
          tokenHistory: parser.historyByPosition[position],
          minPrecedenceLevel: minPrecedenceLevel,
        ),
      );
      nextFrame.nextStates.add(state);

      if (predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        // Next frame belongs to a predicate branch and counts as pending.
        final tracker =
            parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
        // The newly materialized next-frame is pending work for this predicate.
        tracker?.addPendingFrame();
      }

      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
  }

  /// Compute same-position closure for a frame via `_currentWorkList`.
  ///
  /// In ambiguity mode, each distinct mark branch is processed independently.
  void processFrame(Frame frame) {
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeFirst();
      if (!frame.replay) {
        if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
          // Contract note:
          // Being in a predicate stack does not strictly guarantee tracker
          // presence here because exhaustion cleanup can remove a tracker before
          // all delayed frames are drained.
          // This context belongs to a predicate sub-parse; update its tracker.
          final tracker =
              parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (tracker != null) {
            // Work unit is now being processed; decrement "pending work" counter.
            tracker.removePendingFrame();
          }
        }
      }
      _process(Frame(context, replay: frame.replay), state);
    }
    // _finalize will be called by processTokenInternal after all frames are done
  }
}

base mixin ParserCore on GlushParserBase {
  /// Bucket frames by their pivot position into the global work queue.
  ///
  /// The parser may hold frames from multiple pivots simultaneously when calls
  /// and predicates create lagging continuations.
  void enqueueFramesForPositionInternal(
    SplayTreeMap<int, List<Frame>> workQueue,
    List<Frame> frames,
  ) {
    for (final frame in frames) {
      // Pivot is the position where this frame should resume.
      final position = frame.context.pivot ?? 0;
      workQueue.putIfAbsent(position, () => []).add(frame);
    }
  }

  /// Detect predicates that can now be resolved as exhausted (no active frames).
  ///
  /// This method repeatedly drains newly-exhausted trackers because resolving one
  /// predicate can decrement parent predicate counters and trigger further
  /// exhaustion in the same position.
  void checkExhaustedPredicatesInternal(
    SplayTreeMap<int, List<Frame>> workQueue,
    int currentPosition,
  ) {
    bool changed = true;
    // Repeat until no predicate resolution can trigger further parent updates.
    while (changed) {
      changed = false;
      final toRemove = <(PatternSymbol, int)>{};
      // Resolving one predicate can unblock another predicate in the same pass.
      for (final entry in predicateTrackers.entries) {
        final tracker = entry.value;
        if (tracker.canResolveFalse) {
          // No live branches remain, so the predicate failed.
          for (final (_, parentContext, nextState) in tracker.waiters) {
            final predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              final parentTracker =
                  predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              if (parentTracker != null) {
                parentTracker.removePendingFrame();
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              final targetPosition = parentContext.pivot ?? 0;
              final nextFrame = Frame(parentContext)..nextStates.add(nextState);
              if (parentContext.predicateStack.lastOrNull case var pk?) {
                predicateTrackers[(pk.pattern, pk.startPosition)]?.addPendingFrame();
              }
              workQueue.putIfAbsent(targetPosition, () => []).add(nextFrame);
            }
          }
          tracker.waiters.clear();
          toRemove.add(entry.key);
          changed = true;
        } else if (tracker.matched) {
          // Successful predicates can be removed once their waiters drain.
          toRemove.add(entry.key);
        }
      }
      for (final key in toRemove) {
        predicateTrackers.remove(key);
      }
    }
  }

  /// Core single-token processing pipeline.
  ///
  /// High-level sequence:
  /// 1) append token to history (for lagging pivot replay)
  /// 2) run a position-ordered work queue up to `currentPosition`
  /// 3) for each position: process frames, finalize token transitions
  /// 4) run exhausted-predicate catch-up when queue boundary is reached
  /// 5) return the `Step` associated with `currentPosition`
  Step processTokenInternal(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
  }) {
    if (token != null) {
      // Append token to linked history so lagging pivots can replay lookups.
      final node = TokenNode(token);
      if (historyTail == null) {
        // First token initializes the history chain.
        historyTail = node;
      } else {
        // Later tokens extend the history chain.
        historyTail!.next = node;
        historyTail = node;
      }
      historyByPosition[currentPosition] = node;
    }

    if (historyTail != null) {
      // Keep an always-available pointer for lookups at current position.
      historyByPosition[currentPosition] = historyTail!;
    }

    final stepsAtPosition = <int, Step>{};
    final workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    enqueueFramesForPositionInternal(workQueue, frames);

    while (workQueue.isNotEmpty) {
      final position = workQueue.firstKey()!;
      // Work queue is sorted; once position exceeds current token, stop.
      if (position > currentPosition) break;

      final positionFrames = workQueue.remove(position)!;

      if (stepsAtPosition[position] == null) {
        // Build one Step object per position lazily on first visit.
        final positionToken = (position == currentPosition)
            ? token
            : historyByPosition[position]?.unit;

        stepsAtPosition[position] = Step(
          this,
          positionToken,
          position,
          bsr: bsr,
          markManager: markManager,
          derivationManager: derivationManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        );
      }
      final currentStep = stepsAtPosition[position]!;

      for (final frame in positionFrames) {
        if (!frame.replay) {
          if (frame.context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
            // Contract note mirrors processFrame():
            // tracker can be absent after cleanup of an exhausted predicate.
            // Dequeued predicate-owned frame consumes one pending work unit.
            final tracker = predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
            if (tracker != null) {
              // Frame left the queue and is about to be processed at this position.
              tracker.removePendingFrame();
            }
          }
        }
        currentStep.processFrame(frame);
      }

      currentStep.finalize();

      final nextQueuedPosition = workQueue.isEmpty ? null : workQueue.firstKey()!;
      if (nextQueuedPosition == null || nextQueuedPosition > currentPosition) {
        // Logical meaning:
        // - either there is no queued work left, or
        // - the next queued pivot is strictly after `currentPosition`
        // => there is no more work that could still produce predicate matches
        // at/before this boundary, so exhaustion checks are safe now.
        checkExhaustedPredicatesInternal(workQueue, currentPosition);
      }

      if (position < currentPosition) {
        // Earlier positions may generate future-position token transitions.
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
          derivationManager: derivationManager,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        )..finalize());
  }
}
