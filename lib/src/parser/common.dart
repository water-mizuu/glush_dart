import "dart:collection";

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/interface.dart";
import "package:glush/src/parser/state_machine.dart";
import "package:glush/src/representation/bsr.dart";
import "package:glush/src/representation/sppf.dart";
import "package:meta/meta.dart";

// ---------------------------------------------------------------------------
// Type aliases for complex record types used as keys and internal state
// ---------------------------------------------------------------------------

/// Key for tracking lookahead predicate sub-parses by pattern and start position.
typedef PredicateKey = (PatternSymbol pattern, int startPosition);

/// Partner-end rendezvous for negations
typedef NegationKey = (PatternSymbol pattern, int startPosition);

/// Key for tracking conjunction sub-parses by left/right patterns and start position.
typedef ConjunctionKey = (PatternSymbol left, PatternSymbol right, int startPosition);

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

/// Sealed result type returned by parser.parse().
sealed class ParseOutcome {}

/// Returned when parsing fails.
final class ParseError extends ParseOutcome implements Exception {
  ParseError(this.position);
  final int position;
  @override
  String toString() => "ParseError at position $position";
}

final class NegationCallerKey implements CallerKey {
  NegationCallerKey(this.pattern, this.startPosition);
  final PatternSymbol pattern;
  final int startPosition;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NegationCallerKey &&
          pattern == other.pattern &&
          startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(pattern, startPosition);

  @override
  String toString() => "neg($pattern @ $startPosition)";
}

/// Returned when parsing succeeds (marks-based parse).
final class ParseSuccess extends ParseOutcome {
  ParseSuccess(this.result);
  final ParserResult result;
}

/// Returned when parsing succeeds with an ambiguous forest.
final class ParseAmbiguousForestSuccess extends ParseOutcome {
  ParseAmbiguousForestSuccess(this.forest);
  final GlushList<Mark> forest;
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess extends ParseOutcome {
  ParseForestSuccess(this.forest);
  final ParseForest forest;
  @override
  String toString() => "ParseForestSuccess(forest=$forest)";
}

/// Stateful cursor for manual state-machine parsing.
///
/// This standardizes the low-level token processing API by carrying the frame
/// list, current position, and parser flags between calls.
final class ParseState {
  ParseState(
    this.parser, {
    required List<Frame> initialFrames,
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.bsr,
  }) : frames = initialFrames;

  /// The parser definition being executed.
  final GlushParser parser;

  /// True when multiple derivations must be preserved instead of deduped.
  final bool isSupportingAmbiguity;

  /// True when consumed exact tokens should be emitted as `StringMark`s.
  final bool captureTokensAsMarks;

  /// Optional BSR sink used by forest-oriented parser entry points.
  final BsrSet? bsr;

  /// Token history indexed by input position so lagging frames can catch up.
  final Map<int, TokenNode> historyByPosition = {};

  /// Live predicate sub-parses keyed by `(pattern, startPosition)`.
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};

  /// Live conjunction sub-parses keyed by `(left, right, startPosition)`.
  final Map<ConjunctionKey, ConjunctionTracker> conjunctionTrackers = {};

  final Map<NegationKey, NegationTracker> negationTrackers = {};

  /// Memoized call sites keyed by rule and precedence constraints.
  final Map<CallerCacheKey, Caller> callers = {};

  /// Shared mark builder/cache used to keep mark lists persistent and cheap.
  final GlushListCache<Mark> markCache = GlushListCache<Mark>();

  /// Shared derivation builder/cache used only when ambiguity is enabled.
  final GlushListCache<DerivationKey> derivationCache = GlushListCache<DerivationKey>();

  /// Current zero-based input position for the next token to process.
  int position = 0;

  /// Active frames carried forward to the next `processToken` call.
  List<Frame> frames;

  /// Last step produced by the parser, used for final accept/match results.
  Step? _lastStep;

  /// Tail pointer for the linked token history chain.
  TokenNode? historyTail;

  /// Process one input code unit and advance the parser by one position.
  Step processToken(int unit) {
    var step = parser.processToken(
      unit,
      position,
      frames,
      parseState: this,
      bsr: bsr,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
    );
    // Advance the active frame set to the next parser position.
    frames = step.nextFrames;
    position++;
    _lastStep = step;
    return step;
  }

  /// Finalize the parse at end-of-input.
  Step finish() {
    var step = parser.processToken(
      null,
      position,
      frames,
      parseState: this,
      bsr: bsr,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
    );
    _lastStep = step;
    return step;
  }

  /// The most recent step returned by [processToken] or [finish].
  Step? get lastStep => _lastStep;

  StateMachine get stateMachine => parser.stateMachine;

  GrammarInterface get grammar => parser.grammar;

  /// Whether the most recent step accepted the full input.
  bool get accept => _lastStep?.accept ?? false;

  /// Marks from the most recent step.
  List<Mark> get marks => _lastStep?.marks ?? const [];
}

// ---------------------------------------------------------------------------

/// Holds the results of a basic parse() operation.
class ParserResult {
  ParserResult(this._rawMarks);
  final List<Mark> _rawMarks;

  List<Mark> get rawMarks => _rawMarks;

  List<String> get marks {
    var result = <String>[];
    StringBuffer? currentStringMark;

    for (var mark in _rawMarks) {
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
  TokenNode(this.unit);
  final int unit;
  TokenNode? next;
}

/// Tracks one lookahead sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same predicate from multiple branches, so the
/// tracker counts how many predicate-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the predicate as matched
/// or exhausted, and then wake any parked continuations.
class PredicateTracker {
  PredicateTracker(this.symbol, this.startPosition, {required this.isAnd});
  final PatternSymbol symbol;
  final int startPosition;
  final bool isAnd;
  int activeFrames = 0;
  bool matched = false;
  final List<(ParseNodeKey? source, Context, State)> waiters = [];

  /// Mark one predicate-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one predicate-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      "PredicateTracker underflow: removePendingFrame() called with no pending frames.",
    );
    activeFrames--;
  }

  /// True when the predicate can no longer succeed and has not matched.
  bool get canResolveFalse => !matched && activeFrames == 0;
}

/// Tracks one consuming conjunction sub-parse (intersection) for `(left, right, startPosition)`.
///
/// Both sides (A and B) are run independently from the same start position.
/// When both find a match ending at the same position `j`, they rendezvous
/// and resume the main parse at `j`.
class ConjunctionTracker {
  ConjunctionTracker({
    required this.leftSymbol,
    required this.rightSymbol,
    required this.startPosition,
  });
  final PatternSymbol leftSymbol;
  final PatternSymbol rightSymbol;
  final int startPosition;

  final Map<int, List<GlushList<Mark>>> leftCompletions = {};
  final Map<int, List<GlushList<Mark>>> rightCompletions = {};
  int activeFrames = 0;

  final List<(ParseNodeKey? source, Context, State)> waiters = [];

  void addPendingFrame() {
    activeFrames++;
  }

  void removePendingFrame() {
    assert(activeFrames > 0, "ConjunctionTracker underflow");
    activeFrames--;
  }

  bool get isExhausted => activeFrames == 0;
}

/// Tracks one negation sub-parse for a specific `(pattern, startPosition)`.
///
/// The parser may enter the same negation from multiple branches, so the
/// tracker counts how many negation-owned frames are still live (`activeFrames`).
/// Once all branches finish, the tracker can resolve the negation as matched
/// or exhausted, and then wake any parked continuations.
class NegationTracker {
  NegationTracker(this.symbol, this.startPosition);
  final PatternSymbol symbol;
  final int startPosition;
  int activeFrames = 0;

  /// Set of end positions j that the sub-parse A matched.
  final Set<int> matchedPositions = <int>{};

  /// Map of end positions j to waiters that should resume if A does NOT match j.
  final Map<int, List<(ParseNodeKey? source, Context, State)>> waiters = {};

  /// Add a waiter for a specific end position.
  void addWaiter(int endPosition, (ParseNodeKey? source, Context, State) waiter) {
    waiters.putIfAbsent(endPosition, () => []).add(waiter);
  }

  /// Record that the sub-parse matched [endPosition] and cancel any parked waiters there.
  void markMatchedPosition(int endPosition) {
    matchedPositions.add(endPosition);
    waiters.remove(endPosition);
  }

  /// Whether a waiter for [endPosition] is still parked.
  bool hasWaiterAt(int endPosition) => waiters.containsKey(endPosition);

  /// Mark one negation-owned frame as live.
  void addPendingFrame() {
    activeFrames++;
  }

  /// Mark one negation-owned frame as finished.
  void removePendingFrame() {
    assert(
      activeFrames > 0,
      "NegationTracker underflow: removePendingFrame() called with no pending frames.",
    );
    activeFrames--;
  }

  /// True when the negation sub-parse is fully exhausted.
  bool get isExhausted => activeFrames == 0;
}

// ---------------------------------------------------------------------------
// Internal parsing machinery
// ---------------------------------------------------------------------------

/// Strongly typed key to identify a call site in the parsing state machine.
@immutable
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
  const PredicateCallerKey(this.pattern, this.startPosition);

  final PatternSymbol pattern;
  final int startPosition;

  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey &&
      pattern == other.pattern &&
      startPosition == other.startPosition;

  @override
  int get hashCode => Object.hash(pattern, startPosition);
}

/// Caller key for a conjunction sub-parse branch.
final class ConjunctionCallerKey extends CallerKey {
  const ConjunctionCallerKey({
    required this.left,
    required this.right,
    required this.startPosition,
    required this.isLeft,
  });

  final PatternSymbol left;
  final PatternSymbol right;
  final int startPosition;
  final bool isLeft;

  @override
  bool operator ==(Object other) =>
      other is ConjunctionCallerKey &&
      left == other.left &&
      right == other.right &&
      startPosition == other.startPosition &&
      isLeft == other.isLeft;

  @override
  int get hashCode => Object.hash(left, right, startPosition, isLeft);
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
final class Caller extends CallerKey {
  Caller(this.rule, this.pattern, this.startPosition, this.minPrecedenceLevel);
  final Rule rule;
  final Pattern pattern;
  final int startPosition;
  final int? minPrecedenceLevel;
  final List<WaiterInfo> waiters = [];
  final List<Context> returns = [];
  final Set<(CallerKey?, State, int?, Context)> _waiterKeys = {};
  final Set<Context> _returnSet = {};

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
    var waiterKey = (parent, next, minPrecedence, callerContext);
    if (!_waiterKeys.add(waiterKey)) {
      return false;
    }
    waiters.add((parent, next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(Context context) {
    if (!_returnSet.add(context)) {
      return false;
    }
    returns.add(context);
    return true;
  }

  Iterable<(CallerKey?, Context)> iterate() sync* {
    for (var (key, _, _, context, _) in waiters) {
      yield (key, context);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
@immutable
class Context {
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
    if (identical(nextMarks, marks)) {
      return this;
    }
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
    if (identical(nextCaller, caller)) {
      return this;
    }
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
    if (identical(nextCaller, caller) && identical(nextMarks, marks)) {
      return this;
    }

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
  Frame(this.context, {this.replay = false}) : nextStates = {};
  final Context context;
  final Set<State> nextStates;
  final bool replay;
  Frame copy() => Frame(context);
  CallerKey? get caller => context.caller;
  GlushList<Mark> get marks => context.marks;
}

/// Single parsing step at one input position.
class Step {
  Step(
    this.parseState,
    this.token,
    this.position, {
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.bsr,
  });
  final ParseState parseState;
  final int? token;
  final int position;
  final BsrSet? bsr;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;
  final List<Frame> nextFrames = [];
  final Map<ContextKey, List<GlushList<Mark>>> _nextFrameGroups = {};
  final Map<ContextKey, Set<GlushList<Mark>>> _activeContexts = {};
  final Queue<AcceptedContext> _currentWorkList = DoubleLinkedQueue();
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
        "Invariant violation in requeue: predicate stack lookup implies non-empty stack.",
      );
      // A requeued predicate frame is still live work for that tracker.
      parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)]
          ?.addPendingFrame();
    }

    if (frame.context.caller case ConjunctionCallerKey caller) {
      parseState.conjunctionTrackers[(caller.left, caller.right, caller.startPosition)]
          ?.addPendingFrame();
    }
  }

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
      for (var (source, parentContext, nextState) in tracker.waiters) {
        var predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          var parentTracker =
              parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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
      for (var (source, parentContext, nextState) in tracker.waiters) {
        var predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          var parentTracker =
              parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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

  /// Resolve a conjunction match and wake up any waiters at the matching position.
  void _finishConjunction(
    ConjunctionTracker tracker,
    int endPosition,
    bool isLeft,
    GlushList<Mark> marks,
  ) {
    if (isLeft) {
      tracker.leftCompletions.putIfAbsent(endPosition, () => []).add(marks);
      if (tracker.rightCompletions.containsKey(endPosition)) {
        _resumeConjunctionWaiters(tracker, endPosition);
      }
    } else {
      tracker.rightCompletions.putIfAbsent(endPosition, () => []).add(marks);
      if (tracker.leftCompletions.containsKey(endPosition)) {
        _resumeConjunctionWaiters(tracker, endPosition);
      }
    }
  }

  void _resumeConjunctionWaiters(ConjunctionTracker tracker, int endPosition) {
    var leftOptions = tracker.leftCompletions[endPosition] ?? [];
    var rightOptions = tracker.rightCompletions[endPosition] ?? [];

    for (var (source, parentContext, nextState) in tracker.waiters) {
      for (var l in leftOptions) {
        for (var r in rightOptions) {
          // Combine marks from both branches into a ConjunctionMark
          var conMark = ConjunctionMark([l, r], endPosition);
          var nextMarks = parentContext.marks.add(parseState.markCache, conMark);
          var nextContext = parentContext.copyWith(pivot: endPosition, marks: nextMarks);

          if (isSupportingAmbiguity && source != null) {
            // Record the conjunction completion in the derivation path
            var nextPath = parseState.derivationCache.push(parentContext.derivationPath, (
              source,
              "conj", // Special marker for conjunction completion
              null,
            ));
            nextContext = nextContext.copyWith(derivationPath: nextPath);
          }

          requeue(Frame(nextContext)..nextStates.add(nextState));
        }
      }
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
      var nextBranchKey =
          branchKey ?? PredicateAction(isAnd: isAnd, symbol: symbol, nextState: nextState);
      var nextPath = parseState.derivationCache.push(parentContext.derivationPath, (
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
    var states = parseState.parser.stateMachine.ruleFirst[symbol];
    // Missing entry states indicates invalid predicate target symbol.
    if (states == null) {
      // Predicates must map to rule entries in the state machine.
      throw StateError("Predicate symbol must resolve to a rule: $symbol");
    }
    var newPredicateKey = PredicateCallerKey(symbol, position);
    var nextStack = GlushListCache<PredicateCallerKey>().push(
      frame.context.predicateStack,
      newPredicateKey,
    );

    for (var firstState in states) {
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

  /// Seed a conjunction sub-parse (both side A and side B).
  void _spawnConjunctionSubparse(PatternSymbol left, PatternSymbol right, Frame frame) {
    var leftStates = parseState.parser.stateMachine.ruleFirst[left] ?? [];
    var rightStates = parseState.parser.stateMachine.ruleFirst[right] ?? [];

    var leftCaller = ConjunctionCallerKey(
      left: left,
      right: right,
      startPosition: position,
      isLeft: true,
    );
    var rightCaller = ConjunctionCallerKey(
      left: left,
      right: right,
      startPosition: position,
      isLeft: false,
    );

    var subParseKey = (left, right, position);
    var tracker = parseState.conjunctionTrackers[subParseKey];

    // Side A
    for (var s in leftStates) {
      tracker?.addPendingFrame();
      _enqueue(
        s,
        Context(
          leftCaller,
          const GlushList.empty(),
          callStart: position,
          pivot: position,
          tokenHistory: frame.context.tokenHistory,
          predicateStack: frame.context.predicateStack,
        ),
      );
    }

    // Side B
    for (var s in rightStates) {
      tracker?.addPendingFrame();
      _enqueue(
        s,
        Context(
          rightCaller,
          const GlushList.empty(),
          callStart: position,
          pivot: position,
          tokenHistory: frame.context.tokenHistory,
          predicateStack: frame.context.predicateStack,
        ),
      );
    }
  }

  /// Seed a negation sub-parse at the current input position.
  void _spawnNegationSubparse(PatternSymbol symbol, Frame frame) {
    var states = parseState.parser.stateMachine.ruleFirst[symbol];
    // Missing entry states indicates invalid negation target symbol.
    if (states == null) {
      // Negations must map to rule entries in the state machine.
      throw StateError("Negation symbol must resolve to a rule: $symbol");
    }
    var newNegationKey = NegationCallerKey(symbol, position);

    for (var firstState in states) {
      _enqueue(
        firstState,
        Context(
          newNegationKey,
          const GlushList.empty(),
          callStart: position,
          pivot: position,
          tokenHistory: frame.context.tokenHistory,
          predicateStack: frame.context.predicateStack, // Negations inherit parent predicate stack
        ),
      );
    }
  }

  int? _getTokenFor(Frame frame) {
    var framePos = frame.context.pivot ?? 0;
    // Frame already at this step's pivot: use current token directly.
    if (framePos == position) {
      return token;
    }
    // Otherwise pull token from shared history at the frame's pivot.
    return parseState.historyByPosition[framePos]?.unit;
  }

  bool get accept => acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    // No accept state means no valid mark stream.
    if (acceptedContexts.isEmpty) {
      return [];
    }
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
      var nextBranchKey = branchKey ?? action ?? state;
      var nextPath = parseState.derivationCache.push(context.derivationPath, (
        source,
        nextBranchKey,
        callSite,
      ));
      nextContext = context.copyWith(derivationPath: nextPath);
    }

    var targetPosition = nextContext.pivot ?? 0;
    // Queue cross-position work instead of mixing pivots in this step.
    if (targetPosition != position) {
      // Cross-position work is deferred to preserve position-order semantics.
      requeue(Frame(nextContext)..nextStates.add(state));
      return;
    }

    var key = (
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
      var branches = _activeContexts.putIfAbsent(key, () => <GlushList<Mark>>{});
      if (!branches.add(nextContext.marks)) {
        return;
      }
    } else {
      // In non-forest mode, keep only the first equivalent context.
      if (_activeContexts.containsKey(key)) {
        return;
      }
      _activeContexts[key] = {nextContext.marks};
    }

    var predicateKey = nextContext.predicateStack.lastOrNull;
    // Predicate-owned frames keep the tracker alive until they are processed.
    if (predicateKey != null) {
      var tracker =
          parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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
    var frameContext = frame.context;
    for (var action in state.actions) {
      var source = (state.id, position, frameContext.caller);
      var callerOrRoot = frame.caller ?? const RootCallerKey();
      switch (action) {
        case TokenAction():
          var token = _getTokenFor(frame);
          // Token actions fire only when a token exists and matches the pattern.
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.marks;
            var terminalSymbol = action.pattern.symbolId;
            var pattern = action.pattern;
            var shouldCapture =
                captureTokensAsMarks || (pattern is Token && pattern.choice is! ExactToken);

            if (terminalSymbol != null) {
              bsr?.addTerminal(terminalSymbol, position, position + 1, token);
            }

            // Capture policy controls whether consumed chars become StringMarks.
            if (shouldCapture) {
              // Emit consumed character as mark for downstream reconstruction.
              newMarks = newMarks.add(
                parseState.markCache,
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
            var nextKey = (
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
              frameContext.derivationPath,
            );
            _nextFrameGroups.putIfAbsent(nextKey, () => []).add(newMarks);
          }
        case BoundaryAction():
          var isMatch = action.kind == BoundaryKind.start ? position == 0 : token == null;
          if (isMatch) {
            _enqueue(
              action.nextState,
              frameContext.withCallerAndMarks(callerOrRoot, frame.marks),
              source: source,
              action: action,
            );
          }
        case MarkAction():
          var mark = NamedMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(
              callerOrRoot,
              frame.marks.add(parseState.markCache, mark),
            ),
            source: source,
            action: action,
          );
        case LabelStartAction():
          var mark = LabelStartMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(
              callerOrRoot,
              frame.marks.add(parseState.markCache, mark),
            ),
            source: source,
            action: action,
          );
        case LabelEndAction():
          var mark = LabelEndMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(
              callerOrRoot,
              frame.marks.add(parseState.markCache, mark),
            ),
            source: source,
            action: action,
          );
        case PredicateAction():
          var symbol = action.symbol;
          var subParseKey = (symbol, position);
          var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);
          var tracker = parseState.predicateTrackers.putIfAbsent(
            subParseKey,
            () => PredicateTracker(symbol, position, isAnd: action.isAnd),
          );
          assert(
            tracker.symbol == symbol && tracker.startPosition == position,
            "Invariant violation in PredicateAction: tracker key and payload diverged.",
          );
          assert(
            tracker.isAnd == action.isAnd,
            "Invariant violation in PredicateAction: mixed AND/NOT trackers share "
            "the same (symbol,position) key.",
          );

          // A predicate may be re-entered after it has already matched.
          // The tracker has three states:
          // - matched: AND can resume, NOT cannot
          // - unresolved: park this continuation and wait for completion
          // - exhausted false: NOT may resume once all pending branches drain
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

            var predicateKey = frameContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              var parentTracker =
                  parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              // The parent cannot settle until this child branch completes.
              parentTracker?.addPendingFrame();
            }
          }
          // Spawn the sub-parse only the first time this predicate is seen here.
          if (isFirst && !tracker.matched) {
            _spawnPredicateSubparse(symbol, frame);
          }

        case ConjunctionAction():
          var left = action.leftSymbol;
          var right = action.rightSymbol;
          var key = (left, right, position);
          var isFirst = !parseState.conjunctionTrackers.containsKey(key);
          var tracker = parseState.conjunctionTrackers.putIfAbsent(
            key,
            () => ConjunctionTracker(leftSymbol: left, rightSymbol: right, startPosition: position),
          );

          // Park the continuation
          tracker.waiters.add((source, frameContext, action.nextState));

          if (isFirst) {
            _spawnConjunctionSubparse(left, right, frame);
          }

        case NegationAction():
          var symbol = action.symbol;
          var key = (symbol, position);
          var isFirst = !parseState.negationTrackers.containsKey(key);
          var tracker = parseState.negationTrackers.putIfAbsent(
            key,
            () => NegationTracker(symbol, position),
          );

          // Probing: If a pivot is set, we are waiting for this negation to NOT match that pivot.
          var targetJ = frame.context.pivot;
          if (targetJ != null) {
            if (tracker.matchedPositions.contains(targetJ)) {
              // This span has already been proved impossible.
            } else if (tracker.isExhausted) {
              // The child sub-parse is already complete, so the result is final.
              _resumeLaggedPredicateContinuation(
                source: source,
                parentContext: frame.context,
                nextState: action.nextState,
                isAnd: true,
                symbol: action.symbol,
                branchKey: action,
              );
            } else if (!tracker.hasWaiterAt(targetJ)) {
              tracker.addWaiter(targetJ, (source, frameContext, action.nextState));
            }
          } else {
            // Unconstrained negation: This is a design-time warning/error in spec,
            // but for now we just ignore it or log it.
            // In a better implementation, we might try to match ALL possible j.
          }

          if (isFirst) {
            _spawnNegationSubparse(symbol, frame);
          }

        case CallAction():
          CallerCacheKey key = (action.rule, position, action.minPrecedenceLevel);
          var isNewCaller = !parseState.callers.containsKey(key);
          var caller = parseState.callers[key];
          assert(
            isNewCaller == (caller == null),
            "Invariant violation in CallAction: caller cache containsKey/get mismatch.",
          );
          // Create caller node if no memoized node exists for this key yet.
          caller ??= parseState.callers[key] = Caller(
            action.rule,
            action.pattern,
            position,
            action.minPrecedenceLevel,
          );
          var isNewWaiter = caller.addWaiter(
            frame.caller,
            action.returnState,
            action.minPrecedenceLevel,
            frame.context,
            (state.id, position, frame.context.caller),
          );
          // New caller needs initial rule-entry seeding.
          if (isNewCaller) {
            // First time this caller key appears: seed rule entry states.
            var states = parseState.parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
            for (var firstState in states) {
              _enqueue(
                firstState,
                Context(
                  caller,
                  const GlushList.empty(),
                  predicateStack: frame.context.predicateStack,
                  bsrRuleSymbol: action.rule.symbolId,
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
            for (var returnContext in caller.returns) {
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
          var states = parseState.parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
          for (var firstState in states) {
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

          var caller = frame.caller;
          var callStart =
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
              "Invariant violation in ReturnAction: predicate caller should be the top of predicateStack.",
            );
            var tracker = parseState.predicateTrackers[(caller.pattern, caller.startPosition)];
            if (tracker == null) {
              // The predicate may already have resolved in this position.
              continue;
            }

            _finishPredicate(tracker, true);
            continue;
          }

          if (caller is ConjunctionCallerKey) {
            var key = (caller.left, caller.right, caller.startPosition);
            var tracker = parseState.conjunctionTrackers[key];
            if (tracker != null) {
              _finishConjunction(tracker, position, caller.isLeft, frame.marks);
            }
            continue;
          }

          if (caller is NegationCallerKey) {
            var key = (caller.pattern, caller.startPosition);
            var tracker = parseState.negationTrackers[key];
            if (tracker != null) {
              tracker.markMatchedPosition(position);
            }
            continue;
          }

          if (caller is Caller) {
            // Record completion edges for each parent waiter.
            for (var (_, context) in caller.iterate()) {
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
            var returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
            // Replay to waiters only when this return context is newly added.
            if (caller.addReturn(returnContext)) {
              // Newly discovered return context fan-outs to all queued waiters.
              for (var waiter in caller.waiters) {
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
          var accepted = (state, frame.context);
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
      "Invariant violation in _triggerReturn: parent Caller requires parentContext.callStart.",
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
    GlushList<Mark> nextMarks;
    if (parentContext.marks.isEmpty) {
      nextMarks = returnContext.marks;
    } else if (returnContext.marks.isEmpty) {
      nextMarks = parentContext.marks;
    } else {
      nextMarks = parseState.markCache
          .branched([parentContext.marks])
          .addList(parseState.markCache, returnContext.marks);
    }

    var nextContext = Context(
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
  void _finalize() {
    for (var MapEntry(:key, value: marksGroup) in _nextFrameGroups.entries) {
      var (state, caller, minPrecedenceLevel, predicateStack, derivationPath) = key;
      var branchedMarks = parseState.markCache.branched(marksGroup);
      var callerStartPosition = (caller is Caller)
          ? caller.startPosition
          : (caller is RootCallerKey ? 0 : null);
      var nextFrame = Frame(
        Context(
          caller,
          branchedMarks,
          derivationPath: derivationPath,
          predicateStack: predicateStack,
          bsrRuleSymbol: caller is Caller ? caller.rule.symbolId! : null,
          callStart: callerStartPosition,
          pivot: position + 1,
          tokenHistory: parseState.historyByPosition[position],
          minPrecedenceLevel: minPrecedenceLevel,
        ),
      );
      nextFrame.nextStates.add(state);

      if (predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        // Next frame belongs to a predicate branch and counts as pending.
        var tracker =
            parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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
    for (var state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_currentWorkList.isNotEmpty) {
      var (state, context) = _currentWorkList.removeFirst();
      if (!frame.replay) {
        if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
          // Contract note:
          // Being in a predicate stack does not strictly guarantee tracker
          // presence here because exhaustion cleanup can remove a tracker before
          // all delayed frames are drained.
          // This context belongs to a predicate sub-parse; update its tracker.
          var tracker =
              parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
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

abstract base class GlushParserBase implements GlushParser {
  /// Initial frames for a fresh parse session.
  @override
  List<Frame> get initialFrames;

  /// Bucket frames by their pivot position into the global work queue.
  ///
  /// The parser may hold frames from multiple pivots simultaneously when calls
  /// and predicates create lagging continuations.
  void _enqueueFramesForPosition(
    ParseState parseState,
    SplayTreeMap<int, List<Frame>> workQueue,
    List<Frame> frames,
  ) {
    for (var frame in frames) {
      // Pivot is the position where this frame should resume.
      var position = frame.context.pivot ?? 0;
      workQueue.putIfAbsent(position, () => []).add(frame);
    }
  }

  /// Detect predicates that can now be resolved as exhausted (no active frames).
  ///
  /// This method repeatedly drains newly-exhausted trackers because resolving one
  /// predicate can decrement parent predicate counters and trigger further
  /// exhaustion in the same position.
  void _checkExhaustedPredicates(
    ParseState parseState,
    SplayTreeMap<int, List<Frame>> workQueue,
    int currentPosition,
  ) {
    bool changed = true;
    // Repeat until no predicate resolution can trigger further parent updates.
    while (changed) {
      changed = false;
      var toRemove = <(PatternSymbol, int)>{};
      // Resolving one predicate can unblock another predicate in the same pass.
      for (var entry in parseState.predicateTrackers.entries) {
        var tracker = entry.value;
        if (tracker.canResolveFalse) {
          // No live branches remain, so the predicate failed.
          for (var (_, parentContext, nextState) in tracker.waiters) {
            var predicateKey = parentContext.predicateStack.lastOrNull;
            if (predicateKey != null) {
              var parentTracker =
                  parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
              if (parentTracker != null) {
                parentTracker.removePendingFrame();
                changed = true;
              }
            }

            if (!tracker.isAnd) {
              var targetPosition = parentContext.pivot ?? 0;
              var nextFrame = Frame(parentContext)..nextStates.add(nextState);
              if (parentContext.predicateStack.lastOrNull case var pk?) {
                parseState.predicateTrackers[(pk.pattern, pk.startPosition)]?.addPendingFrame();
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
      for (var key in toRemove) {
        parseState.predicateTrackers.remove(key);
      }
    }
  }

  /// Helper to enqueue a frame at a specific future position.
  void _enqueueAt(
    SplayTreeMap<int, List<Frame>> workQueue,
    int position,
    State state,
    Context context, {
    ParseNodeKey? source,
  }) {
    var frame = Frame(context)..nextStates.add(state);
    workQueue.putIfAbsent(position, () => []).add(frame);
  }

  /// Detect negations that are now fully exhausted and resume surviving waiters.
  void _checkExhaustedNegations(
    ParseState parseState,
    SplayTreeMap<int, List<Frame>> workQueue,
    int currentPosition,
  ) {
    for (var entry in parseState.negationTrackers.entries) {
      var tracker = entry.value;
      if (tracker.isExhausted) {
        // Negation sub-parse is done. Resume any waiter for a position j
        // that was NEVER returned by the sub-parse A.
        for (var MapEntry(key: j, value: waiters) in tracker.waiters.entries) {
          if (!tracker.matchedPositions.contains(j)) {
            // Surviving waiter! Resume at j.
            for (var (source, context, nextState) in waiters) {
              _enqueueAt(workQueue, j, nextState, context, source: source);
            }
          }
        }
        // Keep the tracker in place so later candidate positions can resolve
        // immediately without respawning the child sub-parse.
        tracker.waiters.clear();
      }
    }
  }

  /// Create a reusable manual parse cursor.
  ParseState createParseState({
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    BsrSet? bsr,
  }) {
    return ParseState(
      this,
      initialFrames: initialFrames,
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
      bsr: bsr,
    );
  }

  /// Create a reusable manual parse cursor.
  ParseStateWithBsr createParseStateWithBsr({
    required BsrSet bsr,
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
  }) {
    return ParseStateWithBsr(
      ParseState(
        this,
        initialFrames: initialFrames,
        isSupportingAmbiguity: isSupportingAmbiguity,
        captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        bsr: bsr,
      ),
    );
  }

  /// Backwards-compatible alias for [createParseState].
  ParseState parseState({
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
    BsrSet? bsr,
  }) {
    return createParseState(
      isSupportingAmbiguity: isSupportingAmbiguity,
      captureTokensAsMarks: captureTokensAsMarks,
      bsr: bsr,
    );
  }

  /// Core single-token processing pipeline.
  ///
  /// High-level sequence:
  /// 1) append token to history (for lagging pivot replay)
  /// 2) run a position-ordered work queue up to `currentPosition`
  /// 3) for each position: process frames, finalize token transitions
  /// 4) run exhausted-predicate catch-up when queue boundary is reached
  /// 5) return the `Step` associated with `currentPosition`
  @override
  Step processToken(
    int? token,
    int currentPosition,
    List<Frame> frames, {
    required ParseState parseState,
    BsrSet? bsr,
    bool isSupportingAmbiguity = false,
    bool? captureTokensAsMarks,
  }) {
    if (token != null) {
      // Append token to linked history so lagging pivots can replay lookups.
      var node = TokenNode(token);
      if (parseState.historyTail == null) {
        // First token initializes the history chain.
        parseState.historyTail = node;
      } else {
        // Later tokens extend the history chain.
        parseState.historyTail!.next = node;
        parseState.historyTail = node;
      }
      parseState.historyByPosition[currentPosition] = node;
    }

    if (parseState.historyTail != null) {
      // Current-position lookups should always resolve to the latest token.
      parseState.historyByPosition[currentPosition] = parseState.historyTail!;
    }

    var stepsAtPosition = <int, Step>{};
    var workQueue = SplayTreeMap<int, List<Frame>>((a, b) => a.compareTo(b));

    _enqueueFramesForPosition(parseState, workQueue, frames);

    while (workQueue.isNotEmpty) {
      var position = workQueue.firstKey()!;
      // Work queue is sorted; once position exceeds current token, stop.
      if (position > currentPosition) {
        break;
      }

      var positionFrames = workQueue.remove(position)!;

      if (stepsAtPosition[position] == null) {
        // Build one Step object per position lazily on first visit.
        var positionToken = (position == currentPosition)
            ? token
            : parseState.historyByPosition[position]?.unit;

        stepsAtPosition[position] = Step(
          parseState,
          positionToken,
          position,
          bsr: bsr,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        );
      }
      var currentStep = stepsAtPosition[position]!;

      for (var frame in positionFrames) {
        if (!frame.replay) {
          // Replay frames are bookkeeping-only, so they skip predicate counters.
          if (frame.context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
            // Contract note mirrors processFrame():
            // tracker can be absent after cleanup of an exhausted predicate.
            // Dequeued predicate-owned frame consumes one pending work unit.
            var tracker =
                parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
            if (tracker != null) {
              // Frame left the queue and is about to be processed at this position.
              tracker.removePendingFrame();
            }
          }
        }
        currentStep.processFrame(frame);
      }

      currentStep._finalize();

      var nextQueuedPosition = workQueue.isEmpty ? null : workQueue.firstKey()!;
      if (nextQueuedPosition == null || nextQueuedPosition > currentPosition) {
        // Logical meaning:
        // - either there is no queued work left, or
        // - the next queued pivot is strictly after `currentPosition`
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

    return stepsAtPosition[currentPosition] ??
        (Step(
          parseState,
          token,
          currentPosition,
          bsr: bsr,
          isSupportingAmbiguity: isSupportingAmbiguity,
          captureTokensAsMarks: captureTokensAsMarks ?? this.captureTokensAsMarks,
        ).._finalize());
  }
}

extension type const ParseStateWithBsr(ParseState _) implements ParseState {
  BsrSet get bsr => _.bsr!;
}
