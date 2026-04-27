/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/branch_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/key/context_key.dart";
import "package:glush/src/parser/key/parse_node_key.dart";
import "package:glush/src/parser/key/return_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// Coordinates the parsing operations at a single input position.
///
/// [Step] is responsible for exploring all reachable states and derivation
/// paths for a specific point in the input stream. It manages the local
/// work queue, deduplicates redundant parsing configurations, and handles
/// the merging of ambiguous paths.
///
/// Parsing in Glush is position-ordered: all possible transitions at position `N`
/// are completed (including all epsilon closures) before the parser moves to
/// position `N+1`.
class Step {
  /// Creates a [Step] for the given [position] and [token].
  Step(
    this.parseState,
    this.token,
    this.position, {
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
  });

  /// The global state of the current parsing session.
  final ParseState parseState;

  /// The input token currently being processed at this position.
  ///
  /// This is null if the parser has reached the end of the input.
  final int? token;

  /// The zero-based index of this step in the input stream.
  final int position;

  /// Whether this step should track and preserve ambiguous derivation paths.
  final bool isSupportingAmbiguity;

  /// Whether to include raw input tokens in the resulting mark stream.
  final bool captureTokensAsMarks;

  /// Frames that have consumed the current token and are ready for the next position.
  final List<Frame> nextFrames = [];

  /// Exhaustible predicates discovered while processing this step.
  List<PredicateKey>? exhaustedPredicatesSink;

  /// Groups of frames at the current position, optimized for fast context lookup.
  final Map<int, ContextGroup> _currentFrameGroupsInt = {};
  final Map<ComplexContextKey, ContextGroup> _currentFrameGroupsComplex = {};

  /// Groups of frames for the next position, used during token transition batching.
  final List<ContextGroup> _nextFrameGroups = [];

  /// Deduplication sets used in non-ambiguity mode to prune redundant paths.
  final Set<int> _activeContextKeysInt = {};
  final Set<ComplexContextKey> _activeContextKeysComplex = {};

  /// A work queue of states that still need to be explored at this position.
  ///
  /// This is used to compute the epsilon closure of the current position's
  /// active states.
  final List<Object> _workQueue = [];
  int _workQueueHead = 0;

  /// Tracks which GSS callers have already returned at this position to avoid
  /// redundant waiter fan-outs.
  final Set<(CallerKey, int)> _returnedCallers = {};

  /// A map of contexts that reached an [AcceptAction], and their associated marks.
  final Map<Context, LazyGlushList<Mark>> acceptedContexts = {};

  /// Frames that have been requeued for later processing (e.g., lagging paths).
  final List<Frame> requeued = [];

  /// Frames that are enqueued for future positions beyond the immediate next one.
  final Map<int, List<Frame>> deferredFramesByPosition = {};

  /// Requeue work for processing at a future step position.
  ///
  /// Frames with [Context.position] different from [position]
  /// are deferred to later processing using the parser's work queue. This keeps
  /// parsing position-ordered: same-position closure is completed before
  /// processing frames that lag behind (frames from sub-parses, predicates, etc.).
  ///
  /// If the frame belongs to a predicate stack, we increase the tracker pending count
  /// because the predicate still has pending work.
  /// Requeues a [frame] for processing at a later position or in a different
  /// context.
  ///
  /// This is used when a parse path must be deferred (e.g., because it is
  /// replaying historical tokens or waiting for a sub-parse to resolve).
  void requeue(Frame frame) {
    requeued.add(frame);
    parseState.incrementTrackers(frame.context, "requeue");
  }

  /// Resume a continuation that was parked behind a predicate.
  ///
  /// The frame is requeued at the original parent position so it can catch up
  /// through already-seen input using the parser's token history, just like an
  /// epsilon transition reopening a delayed path.
  /// Resumes a parse path that was waiting for a lookahead predicate.
  void _resumeLaggedPredicateContinuation({
    required ParseNodeKey? source,
    required Context parentContext,
    required LazyGlushList<Mark> parentMarks,
    required State nextState,
    required bool isAnd,
    required PatternSymbol symbol,
    ActionBranchKey? branchKey,
  }) {
    var marks = parentMarks;

    parseState.tracer?.onPredicateResumed(symbol, position, isAnd: isAnd);

    requeue(Frame(parentContext, marks, {nextState}));
  }

  /// Seed a predicate sub-parse at the current input position.
  ///
  /// Predicates are lookahead-only, so their entry states are spawned in a
  /// separate sub-parse that can resolve later and wake parked continuations.
  /// Spawns a new sub-parse to evaluate a lookahead predicate.
  void _spawnPredicateSubparse(PatternSymbol symbol, Frame frame, {required bool isAnd}) {
    var entryState = parseState.parser.stateMachine.ruleFirst[symbol];
    if (entryState == null) {
      throw StateError("Predicate symbol must resolve to a rule: $symbol");
    }
    GlushProfiler.increment("parser.predicates.spawned");
    if (isAnd) {
      GlushProfiler.increment("parser.predicates.and");
    } else {
      GlushProfiler.increment("parser.predicates.not");
    }
    var predicateKey = PredicateCallerKey(symbol, position, isAnd: isAnd);
    var nextStack = frame.context.predicateStack.add(predicateKey);

    parseState.tracer?.onMessage("Spawning sub-parse for predicate: $symbol");

    _enqueue(
      entryState,
      Context(predicateKey, predicateStack: nextStack, callStart: position, position: position),
      const LazyGlushList<Mark>.empty(),
    );
  }

  /// Retrieves the correct token for a frame based on whether it's lagging.
  ///
  /// Frames at the current [Step.position] use the current [token] directly.
  /// Lagging frames (where [Context.position] < [Step.position])
  /// pull their token from [ParseState.historyByPosition] at their specific position.
  /// This allows lagging frames (from deferred sub-parses, predicates, etc.)
  /// to replay historical tokens and catch up.
  /// Retrieves the input token appropriate for the given [frame].
  ///
  /// If the frame is at the current position, it returns the current token.
  /// If the frame is "lagging" (e.g., from a sub-parse), it pulls the historical
  /// token from the parse state.
  @pragma("vm:prefer-inline")
  int? _getTokenFor(Frame frame) {
    var framePos = frame.context.position;
    if (framePos == position) {
      return token;
    }
    if (framePos < 0 || framePos >= parseState.historyByPosition.length) {
      return null;
    }
    return parseState.historyByPosition[framePos];
  }

  /// Initiates a rule call and manages caller memoization.
  ///
  /// This method checks guards, looks up or creates a [Caller] node in the GSS,
  /// and either spawns the rule's entry state or triggers returns from a
  /// memoized caller.
  void _seedRuleCall({
    required Rule targetRule,
    required StateAction action,
    required State returnState,
    required int? minPrecedenceLevel,
    required Frame frame,
    required ParseNodeKey source,
    required State currentState,
  }) {
    GlushProfiler.increment("parser.rule_calls.considered");

    /// LL(1) check before entering a call.
    var symbol = targetRule.symbolId;
    if (symbol != null) {
      var frameToken = _getTokenFor(frame);
      var admissible = parseState.parser.stateMachine.canRuleStartWith(
        symbol,
        frameToken,
        isAtStart: frame.context.position == 0,
      );
      if (!admissible) {
        GlushProfiler.increment("parser.rule_calls.admissibility_rejected");
        return;
      }
    }

    var cacheKey = CallerCacheKey(
      targetRule,
      position,
      minPrecedenceLevel,
      frame.context.predicateStack,
    );

    var caller = parseState.callers[cacheKey];
    var isNewCaller = caller == null;
    if (isNewCaller) {
      GlushProfiler.incrementMiss("parser.callers.cache");
      caller = parseState.callers[cacheKey] = Caller(
        targetRule,
        position,
        minPrecedenceLevel,
        frame.context.predicateStack,
        parseState.callerCounter++,
      );
      GlushProfiler.increment("parser.callers.cache_assign");
    } else {
      GlushProfiler.incrementHit("parser.callers.cache");
    }

    var isNewWaiter = caller.addWaiter(
      returnState,
      minPrecedenceLevel,
      frame.context,
      frame.marks,
      ParseNodeKey(currentState.id, position, frame.context.caller),
    );
    if (isNewWaiter) {
      parseState.tracer?.onAction(action, "addedWaiter");
      GlushProfiler.increment("parser.callers.new_waiter");
    }

    /// If we are a new call (at this position),
    if (isNewCaller) {
      GlushProfiler.increment("parser.callers.spawned");
      var firstState = parseState.parser.stateMachine.ruleFirst[targetRule.symbolId!]!;
      parseState.tracer?.onRuleCall(targetRule, position, caller, currentState, firstState);
      _enqueue(
        firstState,
        Context(
          caller,
          predicateStack: frame.context.predicateStack,
          callStart: position,
          position: position,
          minPrecedenceLevel: minPrecedenceLevel,
        ),
        const LazyGlushList<Mark>.empty(),
        source: source,
        action: action,
        callSite: ParseNodeKey(currentState.id, position, frame.context.caller),
      );
    } else if (isNewWaiter) {
      GlushProfiler.increment("parser.callers.early_returns");
      for (var (returnContext, _) in caller.returns) {
        _triggerReturn(
          caller,
          frame.context.caller,
          returnState,
          minPrecedenceLevel,
          frame.context,
          frame.marks,
          returnContext,
          source: ParseNodeKey(currentState.id, position, frame.context.caller),
          action: action,
          callSite: ParseNodeKey(currentState.id, position, frame.context.caller),
        );
      }
    }
  }

  bool get accept => acceptedContexts.isNotEmpty;

  /// Enqueue an active parser configuration for processing at this step.
  ///
  /// If the context's [Context.position] differs from this
  /// [Step.position], the frame is deferred (requeued) instead of processed
  /// immediately. This maintains position-ordered semantics: same-position
  /// closure is completed before processing frames that lag behind.
  ///
  /// Deduplication key is `(state, caller, minPrecedence, predicateStack)`.
  /// In ambiguity mode we still preserve distinct mark branches even when the
  /// target configuration is already active, because marks carry the derivation.
  /// Enqueues a parsing configuration to be explored at this step.
  ///
  /// This method performs path deduplication and merging. If the [context] is
  /// for a future position, it is deferred. Otherwise, it is added to the
  /// current work queue.
  void _enqueue(
    State state,
    Context context,
    LazyGlushList<Mark> marks, {
    ParseNodeKey? source,
    StateAction? action,
    ParseNodeKey? callSite,
  }) {
    GlushProfiler.increment("parser.enqueue.calls");
    GlushProfiler.increment("parser.frames.processed");
    var nextContext = context;

    var targetPosition = nextContext.position;
    // If frame's position != current position, defer it for later.
    // This keeps parsing position-ordered (same-position closure first).
    if (targetPosition != position) {
      // Frame is lagging and will be processed when its position comes up.
      GlushProfiler.increment("parser.enqueue.requeued");
      GlushProfiler.increment("parser.frames.requeued");
      parseState.tracer?.onEnqueue(state, targetPosition, "future position");
      requeue(Frame(nextContext, marks, {state}));
      return;
    }

    // Optimized fast-path: check if context is simple and use bit-packed ID
    if (nextContext.isSimple) {
      var packedId =
          (nextContext.caller.uid << 32) |
          (state.id << 8) |
          (nextContext.minPrecedenceLevel ?? 0xFF);

      if (!isSupportingAmbiguity && !_activeContextKeysInt.add(packedId)) {
        GlushProfiler.incrementHit("parser.enqueue.deduplicated");
        GlushProfiler.increment("parser.frames.deduplicated");
        return;
      }

      var group = _currentFrameGroupsInt[packedId];
      if (group != null) {
        GlushProfiler.incrementHit("parser.enqueue.merged");
        group.addMarks(marks);
        return;
      }

      GlushProfiler.incrementMiss("parser.enqueue.merged");
      var newGroup = ContextGroup(state, nextContext)..addMarks(marks);
      _currentFrameGroupsInt[packedId] = newGroup;

      parseState.incrementTrackers(nextContext, "enqueue");
      _workQueue.add(packedId);
      _workQueue.add(state);
    } else {
      // Slow-path for complex contexts
      var key = ComplexContextKey(state, nextContext);

      if (!isSupportingAmbiguity && !_activeContextKeysComplex.add(key)) {
        GlushProfiler.incrementHit("parser.enqueue.deduplicated");
        return;
      }

      var group = _currentFrameGroupsComplex[key];
      if (group != null) {
        GlushProfiler.incrementHit("parser.enqueue.merged");
        group.addMarks(marks);
        return;
      }

      GlushProfiler.incrementMiss("parser.enqueue.merged");
      _activeContextKeysComplex.add(key);

      parseState.incrementTrackers(nextContext, "enqueue");

      // Initialize group and store initial marks.
      _currentFrameGroupsComplex[key] = ContextGroup(state, nextContext)..addMarks(marks);
      _workQueue.add(key);
      _workQueue.add(state);
    }
  }

  /// Execute outgoing actions for one `(frame,state)` pair.
  ///
  /// Token-consuming actions are batched into `_nextFrameGroups` and finalized
  /// together in [finalize], while zero-width actions (epsilon transitions)
  /// are enqueued immediately. This split avoids interleaving same-position
  /// closure with next-position work.
  /// Processes all actions for a specific state in the given frame.
  ///
  /// This is where the state machine's logic is executed for a single parse
  /// path. It dispatches to specific `_process...` methods based on the action
  /// type.
  void _process(Frame frame, State state) {
    // Iterate over all possible actions originating from the current state.
    for (var action in state.actions) {
      // Note: TokenAction reports its result (o matched or x rejected) after processing,
      // not before. All other actions report "processing" before execution.
      switch (action) {
        case TokenAction():
          _processTokenAction(frame, state, action);
        case BoundaryAction():
          parseState.tracer?.onAction(action, "processing");
          _processBoundaryAction(frame, state, action);
        case LabelStartAction():
          parseState.tracer?.onAction(action, "processing");
          _processLabelStartAction(frame, state, action);
        case LabelEndAction():
          parseState.tracer?.onAction(action, "processing");
          _processLabelEndAction(frame, state, action);
        case PredicateAction():
          parseState.tracer?.onAction(action, "processing");
          _processPredicateAction(frame, state, action);
        case CallAction():
          _processCallAction(frame, state, action);
        case TailCallAction():
          parseState.tracer?.onAction(action, "processing");
          _processTailCallAction(frame, state, action);
        case RetreatAction():
          parseState.tracer?.onAction(action, "processing");
          _processRetreatAction(frame, state, action);
        case ReturnAction():
          parseState.tracer?.onAction(action, "processing");
          _processReturnAction(frame, state, action);
        case AcceptAction():
          parseState.tracer?.onAction(action, "processing");
          _processAcceptAction(frame);
      }
    }
  }

  /// Resume a call-site waiter with one concrete return context.
  ///
  /// This method applies call-site precedence filtering and merges marks as:
  /// `parent marks (prefix) + returned marks (call result)`.
  /// Triggers a return from a rule call back to its caller.
  ///
  /// This method handles precedence filtering, merges the result into the
  /// caller's mark stream, and enqueues the caller's next state
  /// for processing.
  void _triggerReturn(
    Caller caller,
    CallerKey parent,
    State nextState,
    int? minPrecedence,
    Context parentContext,
    LazyGlushList<Mark> parentMarks,
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
      parseState.tracer?.onRuleReturn(caller.rule, position, caller, null);
      return;
    }
    parseState.tracer?.onRuleReturn(caller.rule, position, caller, null);

    var packedId = ReturnKey(
      returnContext.precedenceLevel,
      returnContext.position,
      returnContext.callStart,
    );

    // Use a LazyReturn proxy to represent the (potentially evolving) results of the rule.
    var returnProxy = caller.getLazyReturn(packedId, () => caller.getReturnMarks(packedId));
    var nextMarks = parentMarks.addList(returnProxy);

    /// The next context is the parent context with the returned position
    /// and the returned precedence level.
    var nextContext = Context(
      parent,
      predicateStack: parentContext.predicateStack,
      position: returnContext.position,
    );

    _enqueue(
      nextState,
      nextContext,
      nextMarks,
      source: source,
      action: action,
      callSite: callSite, //
    );
  }

  /// Finalizes the step, processing any pending next-position frames.
  void finalize() {
    for (var nextGroup in _nextFrameGroups) {
      var branchedMarks = nextGroup.mergedMarks;
      var context = nextGroup.context;

      /// Optimization. This does not postpone processing for return actions.
      if (nextGroup.state.actions.length == 1 && nextGroup.state.actions.single is ReturnAction) {
        _process(Frame(context, branchedMarks, {}), nextGroup.state);
        continue;
      }

      var nextFrame = Frame(context, branchedMarks, {nextGroup.state});

      parseState.incrementTrackers(context, "finalize nextGroup");
      nextFrames.add(nextFrame);
    }
  }

  /// Enqueue a frame for processing at the current position.
  /// Enqueues the given [frame] for processing at this step's position.
  void processFrameEnqueue(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      parseState.tracer?.onProcessState(frame, state);
      _enqueue(state, frame.context, frame.marks);
    }
  }

  /// Process all accumulated work from previous processFrameEnqueue() calls.
  /// This must be called after all frames at a position have been enqueued.
  /// Drains the work queue and processes all frames for this step.
  void processFrameFinalize() {
    while (_workQueueHead < _workQueue.length) {
      var key = _workQueue[_workQueueHead++];
      var state = _workQueue[_workQueueHead++] as State;
      ContextGroup? group;
      if (key is int) {
        group = _currentFrameGroupsInt.remove(key);
      } else {
        group = _currentFrameGroupsComplex.remove(key as ComplexContextKey);
      }
      if (group == null) {
        continue;
      }

      var marks = group.mergedMarks;
      var context = group.context;

      exhaustedPredicatesSink?.addAll(parseState.decrementTrackers(context, "processBatch"));
      _process(Frame(context, marks, {}), state);
    }

    if (_workQueueHead != 0) {
      _workQueue.clear();
      _workQueueHead = 0;
    }
  }

  // ============================================================================
  // StateAction Processing Methods
  // ============================================================================
  // The following private methods handle the logic for each StateAction type.
  // They are extracted from the _process method for readability and maintainability.

  /// Processes a [TokenAction], which consumes one input token.
  ///
  /// If the current token matches the action's pattern, a new frame is created
  /// and enqueued for the next position.
  void _processTokenAction(Frame frame, State state, TokenAction action) {
    var token = _getTokenFor(frame);

    GlushProfiler.increment("parser.token_actions.attempted");
    var key = (action.symbolId << 32) | frame.context.position;
    if (parseState.tokenMatches[key] == true) {
      GlushProfiler.increment("parser.token_actions.matched");
      parseState.tracer?.onAction(action, " matched");
      _enqueueToNextPosition(action.nextState, frame.context, frame.marks);

      return;
    }

    if (token != null) {
      if (action.choice.matches(token)) {
        GlushProfiler.increment("parser.token_actions.matched");
        parseState.tracer?.onAction(action, " matched");
        _enqueueToNextPosition(action.nextState, frame.context, frame.marks);
        parseState.tokenMatches[key] = true;

        return;
      }
    }

    GlushProfiler.increment("parser.token_actions.rejected");
    parseState.tracer?.onAction(action, " rejected");
  }

  /// Batches a frame to be processed at the next input position.
  void _enqueueToNextPosition(State nextState, Context context, LazyGlushList<Mark> marks) {
    _nextFrameGroups.add(
      ContextGroup(nextState, context.advancePosition(position + 1))..addMarks(marks),
    );
  }

  /// Enqueues a same-position transition after appending one semantic mark.
  void _enqueueWithAddedMark(
    Frame frame,
    State state,
    StateAction action,
    State nextState,
    LazyVal<Mark> mark,
  ) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    _enqueue(nextState, frameContext, frame.marks.add(mark), source: source, action: action);
  }

  /// Processes a [BoundaryAction], checking for start or end of input.
  void _processBoundaryAction(Frame frame, State state, BoundaryAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var isMatch = action.kind == BoundaryKind.start ? position == 0 : token == null;
    if (isMatch) {
      _enqueue(action.nextState, frameContext, frame.marks, source: source, action: action);
    }
  }

  /// Processes a [LabelStartAction], beginning a labeled capture.
  void _processLabelStartAction(Frame frame, State state, LabelStartAction action) {
    _enqueueWithAddedMark(
      frame,
      state,
      action,
      action.nextState,
      LabelStartVal(action.name, position),
    );
  }

  /// Processes a [LabelEndAction], completing a labeled capture.
  void _processLabelEndAction(Frame frame, State state, LabelEndAction action) {
    _enqueueWithAddedMark(
      frame,
      state,
      action,
      action.nextState,
      LabelEndVal(action.name, position),
    );
  }

  /// Processes a [PredicateAction], initiating a lookahead check.
  void _processPredicateAction(Frame frame, State state, PredicateAction action) {
    var source = ParseNodeKey(state.id, position, frame.context.caller);
    _handlePredicate(
      symbol: action.symbol,
      frame: frame,
      isAnd: action.isAnd,
      source: source,
      nextState: action.nextState,
      action: action,
    );
  }

  /// Unified handler for lookahead predicates.
  ///
  /// This method coordinates between existing trackers and spawning new
  /// sub-parses to resolve a lookahead condition.
  void _handlePredicate({
    required PatternSymbol symbol,
    required Frame frame,
    required bool isAnd,
    required ParseNodeKey source,
    required State nextState,
    StateAction? action,
  }) {
    var frameContext = frame.context;
    var frameToken = _getTokenFor(frame);
    var subParseKey = PredicateKey(symbol, position, isAnd: isAnd);
    var memoizedOutcome = parseState.getMemoizedPredicateOutcome(subParseKey);
    if (memoizedOutcome != null) {
      GlushProfiler.increment("parser.predicates.memoized_hit");
      if (memoizedOutcome == isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: nextState,
          isAnd: isAnd,
          symbol: symbol,
          branchKey: action != null ? ActionBranchKey(action) : null,
        );
      }
      return;
    }

    var admissible = parseState.parser.stateMachine.canRuleStartWith(
      symbol,
      frameToken,
      isAtStart: frameContext.position == 0,
    );
    if (!admissible) {
      GlushProfiler.increment("parser.predicates.admissibility_rejected");
      if (!isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: nextState,
          isAnd: isAnd,
          symbol: symbol,
          branchKey: action != null ? ActionBranchKey(action) : null,
        );
      }
      return;
    }

    var isFirst = !parseState.trackers.containsKey(subParseKey);

    var tracker =
        (parseState.trackers[subParseKey] ??= PredicateTracker(symbol, position, isAnd: isAnd))
            as PredicateTracker;

    assert(
      tracker.symbol == symbol && tracker.startPosition == position,
      "Invariant violation in predicate handler: tracker key and payload diverged.",
    );
    assert(
      tracker.isAnd == isAnd,
      "Invariant violation in predicate handler: mixed AND/NOT trackers share "
      "the same (symbol,position) key.",
    );

    if (tracker.matched) {
      parseState.memoizePredicateOutcome(subParseKey, isMatched: true);
      if (tracker.isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: nextState,
          isAnd: isAnd,
          symbol: symbol,
          branchKey: action != null ? ActionBranchKey(action) : null,
        );
      }
      return;
    }

    if (tracker.exhausted) {
      parseState.memoizePredicateOutcome(subParseKey, isMatched: false);
      if (!isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: nextState,
          isAnd: isAnd,
          symbol: symbol,
          branchKey: action != null ? ActionBranchKey(action) : null,
        );
      }
      return;
    }

    tracker.waiters.add((source, frameContext, nextState, frame.marks));
    parseState.incrementTrackers(frameContext, "childPending");

    if (isFirst) {
      _spawnPredicateSubparse(symbol, frame, isAnd: isAnd);
    }
  }

  /// Processes a [CallAction], calling another rule.
  void _processCallAction(Frame frame, State state, CallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    var targetRule = parseState.stateMachine.allRules[action.ruleSymbol]!;

    _seedRuleCall(
      targetRule: targetRule,
      action: action,
      returnState: action.returnState,
      minPrecedenceLevel: action.minPrecedenceLevel,
      frame: frame,
      source: source,
      currentState: state,
    );
  }

  /// This method resolves caller identity and checks guards, then jumps directly into
  /// the rule's entry state using the [_tailCallTrampoline].
  void _processTailCallAction(Frame frame, State state, TailCallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var firstState = parseState.parser.stateMachine.ruleFirst[action.ruleSymbol];
    if (firstState != null) {
      var tailContext = frame.context.copyWith(
        position: position,
        minPrecedenceLevel: action.minPrecedenceLevel,
      );
      _tailCallTrampoline(firstState, tailContext, frame.marks, source, action);
    }
  }

  /// Executes a trampoline loop for tail-call recursion.
  ///
  /// This optimizes deep recursion by avoiding the overhead of the global work
  /// queue when a rule calls itself (or another rule) in a tail position.
  void _tailCallTrampoline(
    State currentState,
    Context currentContext,
    LazyGlushList<Mark> currentMarks,
    ParseNodeKey source,
    StateAction action,
  ) {
    var state = currentState;
    var context = currentContext;
    var marks = currentMarks;

    while (true) {
      bool hasTailOnlyPath = true;
      TailCallAction? nextTailCall;

      for (var stateAction in state.actions) {
        if (stateAction case TailCallAction tailCall) {
          nextTailCall = tailCall;
        } else {
          hasTailOnlyPath = false;
          break;
        }
      }

      if (hasTailOnlyPath && nextTailCall != null && state.actions.length == 1) {
        var tailCall = nextTailCall;
        var nextFirstState = parseState.parser.stateMachine.ruleFirst[tailCall.ruleSymbol];
        if (nextFirstState == null) {
          return;
        }

        state = nextFirstState;
        context = context.copyWith(
          position: position,
          minPrecedenceLevel: tailCall.minPrecedenceLevel,
        );
        GlushProfiler.increment("parser.tail_call.trampoline_hop");
        continue;
      }

      _enqueue(state, context, marks, source: source, action: action);
      return;
    }
  }

  /// Processes a [RetreatAction], moving the parser back by one position.
  void _processRetreatAction(Frame frame, State state, RetreatAction action) {
    if (position == 0) {
      return;
    }

    var nextContext = frame.context.advancePosition(position - 1);
    _enqueue(action.nextState, nextContext, frame.marks);
  }

  /// Processes a [ReturnAction], returning from a rule call.
  ///
  /// This method performs precedence filtering and manages the settlement of
  /// predicate trackers. For rule calls, it records the result
  /// in the GSS, then notifies all waiting callers.
  void _processReturnAction(Frame frame, State state, ReturnAction action) {
    if (frame.context.minPrecedenceLevel != null &&
        action.precedenceLevel != null &&
        action.precedenceLevel! < frame.context.minPrecedenceLevel!) {
      return;
    }

    var caller = frame.context.caller;
    var returnPosition = frame.context.position;

    if (caller is PredicateCallerKey) {
      assert(
        frame.context.predicateStack.lastOrNull == caller,
        "Invariant violation in ReturnAction: predicate caller should be the top of predicateStack.",
      );
      var key = PredicateKey(caller.pattern, caller.startPosition, isAnd: caller.isAnd);
      var tracker = parseState.trackers[key] as PredicateTracker?;
      if (tracker == null) {
        return;
      }

      bool isNewLongest = tracker.longestMatch == null || returnPosition > tracker.longestMatch!;
      if (!isNewLongest) {
        return;
      }
      tracker.longestMatch = returnPosition;
      tracker.matched = true;
      parseState.memoizePredicateOutcome(key, isMatched: true);

      for (var (source, parentContext, nextState, parentMarks) in tracker.waiters) {
        exhaustedPredicatesSink?.addAll(
          parseState.decrementTrackers(parentContext, "childMatched"),
        );

        if (tracker.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: parentContext,
            parentMarks: parentMarks,
            nextState: nextState,
            isAnd: tracker.isAnd,
            symbol: tracker.symbol,
          );
        }
      }

      tracker.waiters.clear();
      parseState.removeTracker(key);
      return;
    }

    if (!isSupportingAmbiguity && !_returnedCallers.add((caller, returnPosition))) {
      return;
    }

    if (caller is Caller) {
      // End-admissibility is only safe when the exact token at returnPosition is known.
      // If returnPosition > position, we don't have the token yet in this Step.
      if (returnPosition <= position) {
        var returnToken = _getTokenFor(frame);
        var endAdmissible = parseState.parser.stateMachine.canRuleEndWith(
          caller.rule.symbolId!,
          returnToken,
          isAtStart: returnPosition == 0,
        );
        if (!endAdmissible) {
          GlushProfiler.increment("parser.rule_returns.admissibility_rejected");
          return;
        }
      }

      var returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
      if (caller.addReturn(returnContext, frame.marks)) {
        parseState.tracer?.onRuleReturn(caller.rule, returnPosition, caller, state);

        for (var WaiterInfo(:nextState, :minPrecedence, :parentContext, :parentMarks, :callSite)
            in caller.waiters) {
          _triggerReturn(
            caller,
            parentContext.caller,
            nextState,
            minPrecedence,
            parentContext,
            parentMarks,
            returnContext,
            source: ParseNodeKey(state.id, returnPosition, caller),
            action: action,
            callSite: callSite,
          );
        }
      }
    }
  }

  /// Processes an [AcceptAction], indicating a successful parse.
  void _processAcceptAction(Frame frame) {
    var previousMarks = acceptedContexts[frame.context];
    if (previousMarks != null) {
      acceptedContexts[frame.context] = LazyGlushList.branched(previousMarks, frame.marks);
    } else {
      acceptedContexts[frame.context] = frame.marks;
    }
  }
}
