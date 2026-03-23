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

/// Tracks the status of a lookahead sub-parse (AND/NOT predicate).
class PredicateTracker {
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(ParseNodeKey? source, Context, State)> waiters = [];
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

  Context withMarks(GlushList<Mark> nextMarks) {
    if (identical(nextMarks, marks)) return this;
    return Context(
      caller,
      nextMarks,
      predicateStack: predicateStack,
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
      predicateStack: predicateStack,
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
      predicateStack: predicateStack,
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
  final Map<CallerCacheKey, Caller> _callers;
  final Set<CallerKey> _returnedCallers = {};
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
      // Requeued frame still counts as unresolved predicate work.
      // Requeued predicate work is still pending, so keep tracker "alive".
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
  }) : _callers = parser.callers;

  /// Resolve a predicate sub-parse and wake waiting continuations.
  ///
  /// Rules:
  /// - AND predicate (`&`) continues only when matched.
  /// - NOT predicate (`!`) continues only when exhausted without match.
  ///
  /// Parent-predicate `activeFrames` are decremented as waiters are discharged,
  /// which is essential for correct nested-predicate exhaustion logic.
  void _finishPredicate(PredicateTracker tracker, bool matched) {
    // `matched` means the predicate sub-parse proved success at least once.
    if (matched) {
      tracker.matched = true;
      for (final (source, parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        // Parent tracker exists only for nested predicates.
        if (predicateKey != null) {
          // Parent exists only when this predicate is nested.
          final parentTracker =
              parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (parentTracker != null) {
            // Parent tracker may already be cleaned up; decrement only if alive.
            // This waiter is being discharged now; remove one pending unit from
            // the parent predicate's active-work counter.
            parentTracker.activeFrames--;
          }
        }

        // AND predicate continues only on a successful inner parse.
        if (tracker.isAnd) {
          // AND predicate succeeds only when inner parse matched.
          if (isSupportingAmbiguity) {
            // In forest mode keep explicit predicate edge for reconstruction.
            final target = (nextState.id, position, parentContext.caller);
            final predAction = PredicateAction(
              isAnd: tracker.isAnd,
              symbol: tracker.symbol,
              nextState: nextState,
            );
            predecessors.putIfAbsent(target, () => {}).add((
              source,
              predAction,
              const GlushList.empty(),
              null,
            ));
          }
          requeue(Frame(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
    } else if (tracker.activeFrames == 0) {
      // Logical meaning:
      // - no predicate work remains (`activeFrames == 0`)
      // - and we never observed a match (`matched` branch above not taken)
      // => predicate outcome is definitively "not matched".
      for (final (source, parentContext, nextState) in tracker.waiters) {
        final predicateKey = parentContext.predicateStack.lastOrNull;
        // Parent tracker exists only for nested predicates.
        if (predicateKey != null) {
          // Parent exists only when this predicate is nested.
          final parentTracker =
              parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (parentTracker != null) {
            // Parent tracker may already be cleaned up; decrement only if alive.
            // Exhaustion path mirrors matched path: waiter consumed => pending
            // unit removed from parent predicate tracker.
            parentTracker.activeFrames--;
          }
        }

        // NOT predicate continues only when inner parse did not match.
        if (!tracker.isAnd) {
          // NOT predicate succeeds only when inner parse is exhausted unmatched.
          if (isSupportingAmbiguity) {
            // In forest mode keep explicit predicate edge for reconstruction.
            final target = (nextState.id, position, parentContext.caller);
            final predAction = PredicateAction(
              isAnd: tracker.isAnd,
              symbol: tracker.symbol,
              nextState: nextState,
            );
            predecessors.putIfAbsent(target, () => {}).add((
              source,
              predAction,
              const GlushList.empty(),
              null,
            ));
          }
          requeue(Frame(parentContext)..nextStates.add(nextState));
        }
      }
      tracker.waiters.clear();
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
  /// In ambiguity mode we still record predecessor edges even when the target
  /// configuration is already active, because edges carry derivation history.
  void _enqueue(
    State state,
    Context context, {
    ParseNodeKey? source,
    StateAction? action,
    GlushList<Mark> marks = const GlushList.empty(),
    ParseNodeKey? callSite,
  }) {
    final targetPosition = context.pivot ?? 0;
    // Queue cross-position work instead of mixing pivots in this step.
    if (targetPosition != position) {
      // Cross-position work is deferred to preserve position-order semantics.
      requeue(Frame(context)..nextStates.add(state));
      return;
    }

    final key = (state, context.caller, context.minPrecedenceLevel, context.predicateStack);
    // Forest mode tracks alternate derivation edges for equivalent contexts.
    if (isSupportingAmbiguity) {
      // Forest mode keeps all edges, even for already-seen target contexts.
      if (source != null) {
        // Keep derivation edge even if target context already exists.
        final target = (state.id, position, context.caller);
        predecessors.putIfAbsent(target, () => {}).add((source, action, marks, callSite));
      }

      final existingMarks = _activeContexts[key];
      // In forest mode, equivalent active context already exists.
      if (existingMarks != null) return;
      _activeContexts[key] = context.marks;
    } else {
      // In non-forest mode, keep only the first equivalent context.
      if (_activeContexts.containsKey(key)) return;
      _activeContexts[key] = context.marks;
    }

    final predicateKey = context.predicateStack.lastOrNull;
    // Predicate bookkeeping applies only inside predicate stacks.
    if (predicateKey != null) {
      // This enqueued unit contributes to predicate "still alive" accounting.
      final tracker = parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
      // Tracker can be missing when predicate already got finalized/cleaned up.
      if (tracker != null) {
        // Tracker can be absent if predicate already resolved and was removed.
        tracker.activeFrames++;
      }
    }

    _currentWorkList.add((state, context));
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
        case SemanticAction():
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks),
            source: source,
            action: action,
          );
        case TokenAction():
          final token = _getTokenFor(frame);
          // Token actions fire only when a token exists and matches the pattern.
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            final pattern = action.pattern;
            final shouldCapture =
                captureTokensAsMarks || (pattern is Token && pattern.choice is! ExactToken);

            // Capture policy controls whether consumed chars become StringMarks.
            if (shouldCapture) {
              // Emit consumed character as mark for downstream reconstruction.
              newMarks = newMarks.add(
                markManager,
                StringMark(String.fromCharCode(token), position),
              );
            }

            // BSR updates are relevant only for normal rule callers.
            if (bsr != null && frame.caller is Caller) {
              // Record token-step contribution to the caller's BSR span.
              final rule = (frame.caller as Caller).rule;
              bsr!.add(rule.symbolId!, frame.context.callStart!, position, position + 1);
            }

            // Batched until finalize() so token-consuming transitions advance
            // together from this position to the next pivot.
            final nextKey = (
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
            // Forest mode records predecessor edges per token transition.
            if (isSupportingAmbiguity) {
              // Keep per-edge mark delta for SPPF/forest reconstruction.
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
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
            action: action,
            marks: deltaMarks,
          );
        case LabelStartAction():
          final mark = LabelStartMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
            action: action,
            marks: deltaMarks,
          );
        case LabelEndAction():
          final mark = LabelEndMark(action.name, position);
          final deltaMarks = const GlushList<Mark>.empty().add(markManager, mark);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(markManager, mark)),
            source: source,
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

          // Predicate already resolved true.
          if (tracker.matched) {
            // Logical meaning: predicate result is already known true.
            // We do not spawn/wait again; just continue according to AND/NOT.
            if (tracker.isAnd) {
              // AND continuation is allowed after successful predicate.
              if (isSupportingAmbiguity) {
                final target = (action.nextState.id, position, frame.context.caller);
                final predAction = PredicateAction(
                  isAnd: action.isAnd,
                  symbol: action.symbol,
                  nextState: action.nextState,
                );
                predecessors.putIfAbsent(target, () => {}).add((
                  source,
                  predAction,
                  const GlushList.empty(),
                  null,
                ));
              }
              requeue(Frame(frame.context)..nextStates.add(action.nextState));
            }
            // Existing tracker with no active work means exhausted false.
          } else if (!isFirst && tracker.activeFrames == 0) {
            // Logical meaning:
            // - this predicate tracker already existed (`!isFirst`)
            // - and currently has no live branches (`activeFrames == 0`)
            // => it is exhausted with no match; NOT can continue immediately.
            if (!tracker.isAnd) {
              // NOT continuation is allowed only when predicate exhausted false.
              if (isSupportingAmbiguity) {
                final target = (action.nextState.id, position, frame.context.caller);
                final predAction = PredicateAction(
                  isAnd: action.isAnd,
                  symbol: action.symbol,
                  nextState: action.nextState,
                );
                predecessors.putIfAbsent(target, () => {}).add((
                  source,
                  predAction,
                  const GlushList.empty(),
                  null,
                ));
              }
              requeue(Frame(frame.context)..nextStates.add(action.nextState));
            }
          } else {
            // Logical meaning:
            // - predicate result is not known yet
            // - park this continuation in waiters
            // - when predicate resolves, waiter will be resumed or dropped
            //
            // `waiters` stores "what to resume later" as:
            //   (source node for forest edge, paused parent context, nextState)
            tracker.waiters.add((
              source,
              frameContext,
              action.nextState,
            ));

            final predicateKey = frameContext.predicateStack.lastOrNull;
            // Nested parent predicate must wait on this child resolution.
            if (predicateKey != null) {
              // Parent exists only when current predicate is nested.
              final parentTracker =
                  parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              // Logical meaning: this parent predicate cannot finish yet
              // because one more child predicate branch is now pending.
              parentTracker?.activeFrames++;
            }
          }
          // Only first unresolved encounter should spawn predicate entry states.
          if (isFirst && !tracker.matched) {
            // First encounter and unresolved => spawn predicate sub-parse.
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
                  callStart: position,
                  pivot: position,
                  tokenHistory: frame.context.tokenHistory,
                  minPrecedenceLevel: action.minPrecedenceLevel,
                ),
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
              frame.context.callStart ?? (caller is Caller ? caller.startPosition : null);
          // Add BSR span only when call-start information is available.
          if (bsr != null && callStart != null) {
            // Persist completed rule span for BSR consumers.
            bsr!.add(action.rule.symbolId!, callStart, frame.context.pivot ?? callStart, position);
          }

          // Predicate callers resolve predicate trackers instead of GSS callers.
          if (caller is PredicateCallerKey) {
            // Predicate returns resolve predicate waiters, not normal call stacks.
            final tracker = parser.predicateTrackers[(caller.pattern, caller.startPosition)];
            if (tracker != null) {
              // Predicate matched; resolve and wake dependent continuations.
              _finishPredicate(tracker, true);
            }
            continue;
          }

          // Caller-scope BSR stitching applies only to real caller nodes.
          if (bsr != null && caller is Caller) {
            // For normal callers, record completion edges for each parent waiter.
            caller.forEach((parent, state, minimumPrecedence, context, node) {
              // Parent must also be a caller node for parent-rule BSR emission.
              if (parent is Caller) {
                // Mirror completion onto parent nonterminal span in BSR.
                bsr!.add(parent.rule.symbolId!, context.callStart!, caller.startPosition, position);
              }
            });
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
          acceptedContexts.add((state, frame.context));
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
    // Call-site can reject returns below its minimum precedence threshold.
    if (minPrecedence != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrecedence) {
      // Waiter's precedence threshold is not met by this return.
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
    // BSR back-link exists only when parent is an actual caller node.
    if (bsr != null && parent is Caller) {
      // Attach parent-call span to returned child span in BSR set.
      bsr!.add(
        parent.rule.symbolId!,
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
        // Next frame belongs to a predicate branch and counts as pending.
        final tracker =
            parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
        // The newly materialized next-frame is pending work for this predicate.
        tracker?.activeFrames++;
      }

      // Forest mode carries grouped predecessor edges forward.
      if (isSupportingAmbiguity) {
        // Carry predecessor edges corresponding to grouped token transitions.
        final target = (state.id, position + 1, caller);
        if (_nextPredecessorGroups[key] case var preds?) {
          // Only add when this grouped key actually has predecessor edges.
          predecessors.putIfAbsent(target, () => {}).addAll(preds);
        }
      }
      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
    _nextPredecessorGroups.clear();
  }

  /// Compute same-position closure for a frame via `_currentWorkList`.
  ///
  /// In ambiguity mode, canonical grouped marks are read from `_activeContexts`
  /// so equivalent contexts share one marks-forest root.
  void processFrame(Frame frame) {
    for (final state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      final (state, context) = _currentWorkList.removeFirst();
      if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        // This context belongs to a predicate sub-parse; update its tracker.
        final tracker =
            parser.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
        if (tracker != null) {
          // Work unit is now being processed; decrement "pending work" counter.
          tracker.activeFrames--;
        }
      }
      final currentMarks = isSupportingAmbiguity
          ? _activeContexts[(
              state,
              context.caller,
              context.minPrecedenceLevel,
              context.predicateStack,
            )]!
          : context.marks;
      // In ambiguity mode, use canonical grouped marks for equivalent contexts.
      _process(Frame(context.withMarks(currentMarks)), state);
    }
    // _finalize will be called by processTokenInternal after all frames are done
  }
}

mixin ParserCore on GlushParserBase {
  TokenNode? historyTail;

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
    Map<ParseNodeKey, Set<PredecessorInfo>> predecessors,
  ) {
    bool changed = true;
    // Repeat until no predicate resolution can trigger further parent updates.
    while (changed) {
      changed = false;
      final toRemove = <(PatternSymbol, int)>{};
      // Fixed-point loop: resolving one tracker can make parent trackers
      // immediately resolvable in the same position.
      for (final entry in predicateTrackers.entries) {
        final tracker = entry.value;
        if (tracker.activeFrames == 0 && !tracker.matched) {
          // Logical meaning:
          // - no pending branches remain (`activeFrames == 0`)
          // - and none succeeded (`!matched`)
          // => predicate is exhausted with false result.
          for (final (source, parentContext, nextState) in tracker.waiters) {
            final predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              // Nested predicate: propagate exhaustion progress to parent.
              final parentTracker =
                  predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              if (parentTracker != null) {
                // Child predicate became exhausted; parent has one fewer pending
                // sub-parse branch.
                parentTracker.activeFrames--;
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              // NOT succeeds exactly on exhausted-without-match.
              final targetPosition = parentContext.pivot ?? 0;
              final predAction = PredicateAction(
                isAnd: tracker.isAnd,
                symbol: tracker.symbol,
                nextState: nextState,
              );
              final target = (nextState.id, targetPosition, parentContext.caller);
              predecessors.putIfAbsent(target, () => {}).add((
                source,
                predAction,
                const GlushList.empty(),
                null,
              ));

              final nextFrame = Frame(parentContext)..nextStates.add(nextState);
              if (parentContext.predicateStack.lastOrNull case var pk?) {
                // Continuation scheduled under parent predicate adds pending work.
                // Scheduling continuation creates new pending predicate work.
                predicateTrackers[(pk.pattern, pk.startPosition)]?.activeFrames++;
              }
              workQueue.putIfAbsent(targetPosition, () => []).add(nextFrame);
            }
          }
          tracker.waiters.clear();
          toRemove.add(entry.key);
          changed = true;
        } else if (tracker.matched) {
          // Logical meaning: predicate already resolved true, so its waiter
          // bookkeeping can be dropped from the tracker map.
          toRemove.add(entry.key);
        }
      }
      for (final key in toRemove) {
        // Clean resolved/exhausted trackers after this fixed-point iteration.
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
    required Map<ParseNodeKey, Set<PredecessorInfo>> predecessors,
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
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        );
      }
      final currentStep = stepsAtPosition[position]!;

      for (final frame in positionFrames) {
        if (frame.context.predicateStack.lastOrNull case var predicateKey?) {
          // Dequeued predicate-owned frame consumes one pending work unit.
          final tracker = predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
          if (tracker != null) {
            // Frame left the queue and is about to be processed at this position.
            tracker.activeFrames--;
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
        checkExhaustedPredicatesInternal(workQueue, currentPosition, predecessors);
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
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
          predecessors: predecessors,
        )..finalize());
  }

  /// Reconstruct branched marks from predecessor graph edges.
  ///
  /// `ReturnAction` edges are special: they splice
  /// `parentForest + ruleForest` using `callSite` linkage.
  ///
  /// `visiting` prevents infinite recursion for cyclic graph fragments.
  GlushList<Mark> extractForestFromGraphInternal(
    ParseNodeKey node,
    Map<ParseNodeKey, GlushList<Mark>> memo,
    Map<ParseNodeKey, Set<PredecessorInfo>> predecessors, [
    Set<ParseNodeKey>? visiting,
  ]) {
    // Memoized forest already computed for this graph node.
    if (memo.containsKey(node)) return memo[node]!;

    final currentVisiting = visiting ?? <ParseNodeKey>{};
    if (currentVisiting.contains(node)) {
      // Cycle guard to prevent infinite recursion on cyclic predecessor graphs.
      return const GlushList<Mark>.empty();
    }

    currentVisiting.add(node);
    final predecessorsForNode = predecessors[node];
    if (predecessorsForNode == null) {
      // No incoming edges means this node contributes an empty fragment.
      return memo[node] = const GlushList<Mark>.empty();
    }

    final alternatives = <GlushList<Mark>>[];
    for (final (source, action, marks, callSite) in predecessorsForNode) {
      if (action is ReturnAction) {
        // Return edges splice callee derivation into caller continuation.
        // Return edges combine callee subtree with caller continuation.
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
        // Non-return edge extends predecessor forest with edge-local marks.
        final base = extractForestFromGraphInternal(source, memo, predecessors, currentVisiting);
        alternatives.add(base.addList(markManager, marks));
      } else {
        // Source-less edge contributes marks directly as one alternative.
        alternatives.add(marks);
      }
    }
    currentVisiting.remove(node);

    final result = markManager.branched(alternatives);
    return memo[node] = result;
  }
}
