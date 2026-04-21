/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/helper/ref.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/label_capture.dart";
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
  final Set<(CallerKey, int)> _returnedCallersPositionAware = {};

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
  /// If the frame belongs to a predicate stack, we increase `activeFrames`
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

  /// Resolve a conjunction match and wake up any waiters at the matching position.
  /// Finalizes one side of a conjunction (A & B).
  ///
  /// When one side of a conjunction completes at an [endPosition], it records
  /// its marks. If the other side has already completed at the same position,
  /// they are combined to resume any waiters.
  void _finishConjunction(
    ConjunctionTracker tracker,
    int endPosition,
    bool isLeft,
    LazyGlushList<Mark> marks,
  ) {
    if (isLeft) {
      tracker.leftCompletions.putIfAbsent(endPosition, () => []).add(marks);
      // Spawn resumptions for each already-available right branch.
      var rightCompletions = tracker.rightCompletions[endPosition] ?? [];
      for (var right in rightCompletions) {
        _triggerConjunctionReturn(tracker, endPosition, marks, right, tracker.waiters);
      }
    } else {
      tracker.rightCompletions.putIfAbsent(endPosition, () => []).add(marks);
      // Spawn resumptions for each already-available left branch.
      var leftCompletions = tracker.leftCompletions[endPosition] ?? [];
      for (var left in leftCompletions) {
        _triggerConjunctionReturn(tracker, endPosition, left, marks, tracker.waiters);
      }
    }
  }

  /// Check for matching pairs on both sides of a conjunction and resume waiters.
  /// Used when a NEW waiter is added and needs to see all existing results.
  /// Checks for matching completions on both sides of a conjunction for specific waiters.
  void _rendezvousConjunction(
    ConjunctionTracker tracker,
    int endPosition,
    List<Waiter> specificWaiters,
  ) {
    var lefts = tracker.leftCompletions[endPosition];
    var rights = tracker.rightCompletions[endPosition];
    if (lefts != null && rights != null) {
      for (var left in lefts) {
        for (var right in rights) {
          _triggerConjunctionReturn(tracker, endPosition, left, right, specificWaiters);
        }
      }
    }
  }

  /// Combines results from both sides of a conjunction and resumes target waiters.
  void _triggerConjunctionReturn(
    ConjunctionTracker tracker,
    int endPosition,
    LazyGlushList<Mark> left,
    LazyGlushList<Mark> right,
    List<(ParseNodeKey? source, Context, State, LazyGlushList<Mark>)> targetWaiters,
  ) {
    // Create a Parallel node representing the cartesian product of left and right marks
    // at the same span. This captures all combinations of parallel marks.
    GlushProfiler.increment("parser.conjunctions.completed");
    var conjunctionResult = LazyGlushList.conjunction(left, right);
    GlushProfiler.increment("parser.marks.conjunctions_created");

    for (var (_, parentContext, nextState, parentMarks) in targetWaiters) {
      // Add the parallel result to the parent marks.
      var nextMarks = parentMarks.addList(conjunctionResult);
      var nextContext = parentContext.advancePosition(endPosition);
      GlushProfiler.increment("parser.marks.added");
      requeue(Frame(nextContext, nextMarks)..nextStates.add(nextState));
    }
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

    requeue(Frame(parentContext, marks)..nextStates.add(nextState));
  }

  /// Seed a predicate sub-parse at the current input position.
  ///
  /// Predicates are lookahead-only, so their entry states are spawned in a
  /// separate sub-parse that can resolve later and wake parked continuations.
  /// Spawns a new sub-parse to evaluate a lookahead predicate.
  void _spawnPredicateSubparse(
    PatternSymbol symbol,
    Frame frame, {
    required bool isAnd,
    String? name,
  }) {
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
    var predicateKey = PredicateCallerKey(symbol, position, isAnd: isAnd, name: name);
    var nextStack = frame.context.predicateStack.add(predicateKey);

    parseState.tracer?.onMessage("Spawning sub-parse for predicate: $symbol");

    _enqueue(
      entryState,
      Context(
        predicateKey,
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        predicateStack: nextStack,
        callStart: position,
        position: position,
      ),
      const LazyGlushList<Mark>.empty(),
    );
  }

  /// Seed a conjunction sub-parse (both side A and side B).
  /// Spawns sub-parses for both sides of a conjunction (A & B).
  void _spawnConjunctionSubparse(PatternSymbol left, PatternSymbol right, Frame frame) {
    GlushProfiler.increment("parser.conjunctions.spawned");
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

    var subParseKey = ConjunctionKey(left, right, position);
    parseState.trackers[subParseKey]!;

    // Side A
    var leftState = parseState.parser.stateMachine.ruleFirst[left];
    if (leftState != null) {
      _enqueue(
        leftState,
        Context(
          leftCaller,
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          position: position,
          predicateStack: frame.context.predicateStack,
        ),
        const LazyGlushList<Mark>.empty(),
      );
    }

    // Side B
    var rightState = parseState.parser.stateMachine.ruleFirst[right];
    if (rightState != null) {
      _enqueue(
        rightState,
        Context(
          rightCaller,
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          position: position,
          predicateStack: frame.context.predicateStack,
        ),
        const LazyGlushList<Mark>.empty(),
      );
    }
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
  int? _getTokenFor(Frame frame) {
    var framePos = frame.context.position;
    if (framePos == position) {
      return token;
    }
    return parseState.historyByPosition[framePos];
  }

  /// Evaluates whether a rule's guard expression allows expansion in the current context.
  ///
  /// Guards are used to enforce semantic constraints or custom dispatch logic.
  /// Evaluates whether a rule's guard condition is satisfied.
  ///
  /// Guards allow for context-sensitive or semantic checks that prune parse
  /// paths early.
  bool _ruleGuardPasses(
    Rule rule,
    Frame frame, {
    required Map<String, Object?> arguments,
    required CallArgumentsKey argumentsKey,
  }) {
    var guard = rule.guard;
    if (guard == null) {
      return true;
    }

    var subjectRule = rule.guardOwner ?? rule;
    var result = GlushProfiler.measure("parser.guard.evaluate", () {
      return guard.evaluate(
        _buildGuardEnvironment(rule: subjectRule, frame: frame, arguments: arguments),
      );
    });
    GlushProfiler.increment("parser.guard.cache_assign");
    return result;
  }

  /// Constructs the semantic environment used for guard evaluation.
  GuardEnvironment _buildGuardEnvironment({
    required Rule rule,
    required Frame frame,
    required Map<String, Object?> arguments,
  }) {
    var values = <String, Object?>{
      "rule": rule,
      "ruleName": rule.name,
      "position": position,
      "callStart": frame.context.callStart,
      "minPrecedenceLevel": frame.context.minPrecedenceLevel,
      "precedenceLevel": frame.context.precedenceLevel,
    };

    return GuardEnvironment(
      rule: rule,
      marks: frame.marks,
      arguments: arguments,
      values: values,
      valuesKey: GuardValuesKey(
        captureSignature: frame.context.captures.signature,
        ruleName: rule.name,
        position: position,
        callStart: frame.context.callStart,
        minPrecedenceLevel: frame.context.minPrecedenceLevel,
        precedenceLevel: frame.context.precedenceLevel,
      ),
      valueResolver: frame.context.captures.isEmpty ? null : (name) => frame.context.captures[name],
      captureResolver: _extractLabelCapture,
      rulesByName: parseState.rulesByName,
    );
  }

  /// Resolves a labeled capture from the current mark stream.
  CaptureValue? _extractLabelCapture(LazyGlushList<Mark> marks, String target) {
    var concreteMarks = marks.evaluate();

    var capture = GlushProfiler.measure("parser.capture.resolve", () {
      var walker = LabelCaptureWalker(target);
      walker.walk(concreteMarks, []);
      var resolved = walker.best;
      if (resolved != null) {
        resolved = CaptureValue(
          resolved.startPosition,
          resolved.endPosition,
          _captureText(resolved.startPosition, resolved.endPosition),
        );
      }
      return resolved;
    });
    GlushProfiler.increment("parser.capture.cache_assign");

    return capture;
  }

  /// Reconstructs the text consumed between two positions.
  String _captureText(int startPosition, int endPosition) {
    GlushProfiler.increment("parser.capture.text_rebuilds");
    var buffer = StringBuffer();
    for (var i = startPosition; i < endPosition; i++) {
      var unit = parseState.historyByPosition[i];

      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  /// Resolves the argument values for a rule call.
  ({Map<String, Object?> arguments, CallArgumentsKey key}) _resolveCallArgumentValues(
    Map<String, CallArgumentValue> args,
    Frame frame,
    Rule targetRule,
  ) {
    if (args.isEmpty) {
      return (arguments: frame.context.arguments, key: const EmptyCallArgumentsKey());
    }

    var callerRule = switch (frame.context.caller) {
      Caller(:var rule) => rule,
      _ => targetRule,
    };
    var callerArguments = frame.context.arguments;
    var env = _buildGuardEnvironment(rule: callerRule, frame: frame, arguments: callerArguments);

    var resolved = <String, Object?>{};
    var resolvedValues = <Object?>[];

    var sortedNames = args.keys.toList()..sort();
    for (var name in sortedNames) {
      var value = args[name]!.resolve(env);
      resolved[name] = value;
      resolvedValues.add(value);
    }

    var key = switch (resolvedValues.length) {
      0 => const EmptyCallArgumentsKey(),
      _ => CompositeCallArgumentsKey(List<Object?>.unmodifiable(resolvedValues)),
    };

    return (arguments: Map<String, Object?>.unmodifiable(resolved), key: key);
  }

  ({Map<String, Object?> arguments, CallArgumentsKey key})? _resolveParameterCallArguments(
    String targetName,
    Map<String, CallArgumentValue> callArgs,
    Frame frame,
    Rule rule,
  ) {
    var callerRule = switch (frame.context.caller) {
      Caller(rule: var callerRule) => callerRule,
      _ => rule,
    };
    var callerArguments = frame.context.arguments;
    var env = _buildGuardEnvironment(rule: callerRule, frame: frame, arguments: callerArguments);

    var resolved = <String, Object?>{};
    var resolvedValues = <Object?>[];

    var sortedNames = callArgs.keys.toList()..sort();
    for (var name in sortedNames) {
      var value = callArgs[name]!.resolve(env);
      resolved[name] = value;
      resolvedValues.add(value);
    }

    var key = switch (resolvedValues.length) {
      0 => const EmptyCallArgumentsKey(),
      _ => CompositeCallArgumentsKey(List<Object?>.unmodifiable(resolvedValues)),
    };

    return (arguments: Map<String, Object?>.unmodifiable(resolved), key: key);
  }

  /// Initiates a rule call and manages caller memoization.
  ///
  /// This method checks guards, looks up or creates a [Caller] node in the GSS,
  /// and either spawns the rule's entry state or triggers returns from a
  /// memoized caller.
  void _seedRuleCall({
    required Rule targetRule,
    required Map<String, Object?> callArguments,
    required CallArgumentsKey callArgumentsKey,
    required StateAction action,
    required State returnState,
    required int? minPrecedenceLevel,
    required Frame frame,
    required ParseNodeKey source,
    required State currentState,
  }) {
    GlushProfiler.increment("parser.rule_calls.considered");
    if (!_ruleGuardPasses(
      targetRule,
      frame,
      arguments: callArguments,
      argumentsKey: callArgumentsKey,
    )) {
      GlushProfiler.increment("parser.rule_calls.guard_rejected");
      return;
    }

    var isSimpleCall = callArgumentsKey is StringCallArgumentsKey && callArgumentsKey.key.isEmpty;
    Caller? caller;
    var isNewCaller = false;

    if (isSimpleCall && frame.context.predicateStack.isEmpty) {
      var packedId = (position << 32) | (targetRule.uid << 8) | (minPrecedenceLevel ?? 0xFF);
      caller = parseState.callersInt[packedId];
      if (caller == null) {
        isNewCaller = true;
        GlushProfiler.incrementMiss("parser.callers.cache");
        caller = parseState.callersInt[packedId] = Caller(
          targetRule,
          position,
          minPrecedenceLevel,
          callArguments,
          frame.context.predicateStack,
          parseState.callerCounter++,
        );
        GlushProfiler.increment("parser.callers.cache_assign");
        GlushProfiler.increment("parser.callers.created_simple");
      } else {
        GlushProfiler.incrementHit("parser.callers.cache");
      }
    } else {
      var key = ComplexCallerCacheKey(
        targetRule,
        position,
        minPrecedenceLevel,
        callArgumentsKey,
        frame.context.predicateStack,
      );
      caller = parseState.callersComplex[key];
      if (caller == null) {
        isNewCaller = true;
        GlushProfiler.incrementMiss("parser.callers.cache");
        caller = parseState.callersComplex[key] = Caller(
          targetRule,
          position,
          minPrecedenceLevel,
          callArguments,
          frame.context.predicateStack,
          parseState.callerCounter++,
        );
        GlushProfiler.increment("parser.callers.cache_assign");
        GlushProfiler.increment("parser.callers.created_complex");
      } else {
        GlushProfiler.incrementHit("parser.callers.cache");
      }
    }
    var isNewWaiter = caller.addWaiter(
      returnState,
      minPrecedenceLevel,
      frame.context,
      Ref(frame.marks),
      ParseNodeKey(currentState.id, position, frame.context.caller),
    );
    if (isNewWaiter) {
      GlushProfiler.increment("parser.callers.new_waiter");
    }
    if (isNewCaller) {
      GlushProfiler.increment("parser.callers.spawned");
      var firstState = parseState.parser.stateMachine.ruleFirst[targetRule.symbolId];
      if (firstState != null) {
        parseState.tracer?.onRuleCall(targetRule, position, caller, currentState, firstState);
        _enqueue(
          firstState,
          Context(
            caller,
            captures: frame.context.captures,
            predicateStack: frame.context.predicateStack,
            callStart: position,
            position: position,
            minPrecedenceLevel: minPrecedenceLevel,
            arguments: callArguments,
          ),
          const LazyGlushList<Mark>.empty(),
          source: source,
          action: action,
          callSite: ParseNodeKey(currentState.id, position, frame.context.caller),
        );
      }
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
      requeue(Frame(nextContext, marks)..nextStates.add(state));
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
      return;
    }

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
      if (action is! TokenAction) {
        parseState.tracer?.onAction(action, "processing");
      }
      switch (action) {
        case TokenAction():
          _processTokenAction(frame, state, action);
        case BoundaryAction():
          _processBoundaryAction(frame, state, action);
        case ParameterStringAction():
          _processParameterStringAction(frame, state, action);
        case MarkAction():
          _processMarkAction(frame, state, action);
        case LabelStartAction():
          _processLabelStartAction(frame, state, action);
        case LabelEndAction():
          _processLabelEndAction(frame, state, action);
        case PredicateAction():
          _processPredicateAction(frame, state, action);
        case ConjunctionAction():
          _processConjunctionAction(frame, state, action);
        case CallAction():
          _processCallAction(frame, state, action);
        case ParameterAction():
          _processParameterAction(frame, state, action);
        case ParameterCallAction():
          _processParameterCallAction(frame, state, action);
        case ParameterPredicateAction():
          _processParameterPredicateAction(frame, state, action);
        case TailCallAction():
          _processTailCallAction(frame, state, action);
        case RetreatAction():
          _processRetreatAction(frame, state, action);
        case ReturnAction():
          _processReturnAction(frame, state, action);
        case AcceptAction():
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

    CaptureBindings mergedCaptures;
    if (parentContext.captures.isEmpty) {
      mergedCaptures = returnContext.captures;
    } else if (returnContext.captures.isEmpty) {
      mergedCaptures = parentContext.captures;
    } else {
      mergedCaptures = parentContext.captures.overlay(returnContext.captures);
    }

    var nextCaller = parent;
    var nextContext = Context(
      nextCaller,
      arguments: parentContext.arguments,
      captures: mergedCaptures,
      predicateStack: parentContext.predicateStack,
      callStart: parentContext.callStart,
      position: returnContext.position,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );

    _enqueue(nextState, nextContext, nextMarks, source: source, action: action, callSite: callSite);
  }

  /// Materialize batched token transitions into next-position frames.
  /// Finalizes the step, processing any pending next-position frames.
  void finalize() {
    for (var nextGroup in _nextFrameGroups) {
      _processNextGroup(nextGroup);
    }
  }

  /// Processes a group of frames that have transitioned to the next position.
  void _processNextGroup(ContextGroup nextGroup) {
    var branchedMarks = nextGroup.mergedMarks;
    var context = nextGroup.context;
    var caller = context.caller;
    var callerStartPosition = caller.startPosition;

    if (context.position != position + 1 || context.callStart != callerStartPosition) {
      context = context.copyWith(position: position + 1, callStart: callerStartPosition);
    }

    if (nextGroup.state.actions.length == 1 && nextGroup.state.actions.single is ReturnAction) {
      _process(Frame(context, branchedMarks), nextGroup.state);
      return;
    }

    var nextFrame = Frame(context, branchedMarks);
    nextFrame.nextStates.add(nextGroup.state);

    parseState.incrementTrackers(context, "finalize nextGroup");
    nextFrames.add(nextFrame);
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

      parseState.decrementTrackers(context, "processBatch");

      _process(Frame(context, marks), state);
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
    var frameContext = frame.context;
    var token = _getTokenFor(frame);

    GlushProfiler.increment("parser.token_actions.attempted");
    if (token != null && action.choice.matches(token)) {
      GlushProfiler.increment("parser.token_actions.matched");
      parseState.tracer?.onAction(action, " matched");
      var newMarks = frame.marks;
      var pattern = action.choice;

      var shouldCapture = captureTokensAsMarks || (pattern is Token && pattern.capturesAsMark);

      if (shouldCapture) {
        GlushProfiler.increment("parser.marks.added");
        newMarks = newMarks.add(StringMarkVal(String.fromCharCode(token), position));
      }

      _enqueueToNextPosition(action.nextState, frameContext, newMarks);
    } else {
      GlushProfiler.increment("parser.token_actions.rejected");
      parseState.tracer?.onAction(action, " rejected");
    }
  }

  /// Batches a frame to be processed at the next input position.
  void _enqueueToNextPosition(State nextState, Context context, LazyGlushList<Mark> marks) {
    _nextFrameGroups.add(
      ContextGroup(nextState, context.advancePosition(position + 1))..addMarks(marks),
    );
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

  /// Processes a [ParameterStringAction], matching a specific code unit.
  void _processParameterStringAction(Frame frame, State state, ParameterStringAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);

    if (token != null && token == action.codeUnit) {
      var newMarks = frame.marks;
      if (captureTokensAsMarks) {
        newMarks = newMarks.add(StringMarkVal(String.fromCharCode(action.codeUnit), position));
      }
      _enqueueToNextPosition(action.nextState, frameContext, newMarks);
    }
  }

  /// Processes a [MarkAction], emitting a named mark.
  void _processMarkAction(Frame frame, State state, MarkAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(NamedMarkVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Processes a [LabelStartAction], beginning a labeled capture.
  void _processLabelStartAction(Frame frame, State state, LabelStartAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(LabelStartVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Processes a [LabelEndAction], completing a labeled capture.
  void _processLabelEndAction(Frame frame, State state, LabelEndAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(LabelEndVal(action.name, position)),
      source: source,
      action: action,
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
    String? name,
    StateAction? action,
  }) {
    var frameContext = frame.context;
    var subParseKey = PredicateKey(symbol, position, isAnd: isAnd, name: name);
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
    }

    if (!tracker.exhausted) {
      tracker.waiters.add((source, frameContext, nextState, frame.marks));
      parseState.incrementTrackers(frameContext, "childPending");
    } else if (tracker.canResolveFalse) {
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
    }

    if (isFirst) {
      _spawnPredicateSubparse(symbol, frame, isAnd: isAnd, name: name);
    }
  }

  /// Processes a [ConjunctionAction], requiring two sub-parses to match.
  void _processConjunctionAction(Frame frame, State state, ConjunctionAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var left = action.leftSymbol;
    var right = action.rightSymbol;
    var key = ConjunctionKey(left, right, position);
    var isFirst = !parseState.trackers.containsKey(key);
    var tracker =
        (parseState.trackers[key] ??= ConjunctionTracker(
              leftSymbol: left,
              rightSymbol: right,
              startPosition: position,
            ))
            as ConjunctionTracker;

    var waiter = (source, frameContext, action.nextState, frame.marks);
    tracker.waiters.add(waiter);

    for (var j in tracker.leftCompletions.keys) {
      _rendezvousConjunction(tracker, j, [waiter]);
    }

    if (isFirst) {
      _spawnConjunctionSubparse(left, right, frame);
    }
  }

  /// Processes a [CallAction], calling another rule.
  void _processCallAction(Frame frame, State state, CallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var targetRule = parseState.rulesById[action.ruleSymbol]!;
    var resolvedCall = _resolveCallArgumentValues(action.arguments, frame, targetRule);

    _seedRuleCall(
      targetRule: targetRule,
      callArguments: resolvedCall.arguments,
      callArgumentsKey: resolvedCall.key,
      action: action,
      returnState: action.returnState,
      minPrecedenceLevel: action.minPrecedenceLevel,
      frame: frame,
      source: source,
      currentState: state,
    );
  }

  /// Processes a [ParameterAction], resolving a dynamic parameter reference.
  void _processParameterAction(Frame frame, State state, ParameterAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.name)) {
      throw StateError("Missing argument '${action.name}' for parameter reference.");
    }

    var value = arguments[action.name];
    switch (value) {
      case String text:
        if (text.isEmpty) {
          _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
          return;
        }
        var entryState = parseState.parser.stateMachine.parameterStringEntry(
          text,
          action.nextState,
        );
        _enqueue(entryState, frame.context, frame.marks, source: source, action: action);
        return;
      case CaptureValue captureValue:
        var entryState = parseState.parser.stateMachine.parameterStringEntry(
          captureValue.value,
          action.nextState,
        );
        _enqueue(entryState, frame.context, frame.marks, source: source, action: action);
      case RuleCall callValue:
        var resolvedCall = _resolveCallArgumentValues(callValue.arguments, frame, callValue.rule);
        _seedRuleCall(
          targetRule: callValue.rule,
          callArguments: resolvedCall.arguments,
          callArgumentsKey: resolvedCall.key,
          action: action,
          returnState: action.nextState,
          minPrecedenceLevel: callValue.minPrecedenceLevel,
          frame: frame,
          source: source,
          currentState: state,
        );
      case Rule rule:
        _seedRuleCall(
          targetRule: rule,
          callArguments: const {},
          callArgumentsKey: const EmptyCallArgumentsKey(),
          action: action,
          returnState: action.nextState,
          minPrecedenceLevel: null,
          frame: frame,
          source: source,
          currentState: state,
        );
      case Eps():
        _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
      case Pattern pattern when pattern.singleToken():
        if (token != null && pattern.match(token)) {
          _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
        }
      case bool matches:
        if (matches) {
          _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
        }
      case Pattern pattern:
        throw UnsupportedError(
          "Complex parser objects used as parameters are not supported yet: ${pattern.runtimeType}",
        );
      default:
        throw UnsupportedError(
          "Unsupported parameter value for ${action.name}: ${value.runtimeType}",
        );
    }
  }

  /// Processes a [ParameterCallAction], calling a rule through a parameter.
  void _processParameterCallAction(Frame frame, State state, ParameterCallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.targetParameter)) {
      throw StateError("Missing argument '${action.targetParameter}' for parameter reference.");
    }

    var value = arguments[action.targetParameter];
    switch (value) {
      case RuleCall callValue:
        var mergedArguments = <String, CallArgumentValue>{
          ...callValue.arguments,
          ...action.arguments,
        };
        var resolvedCall = _resolveCallArgumentValues(mergedArguments, frame, callValue.rule);
        _seedRuleCall(
          targetRule: callValue.rule,
          callArguments: resolvedCall.arguments,
          callArgumentsKey: resolvedCall.key,
          action: action,
          returnState: action.nextState,
          minPrecedenceLevel: callValue.minPrecedenceLevel ?? action.minPrecedenceLevel,
          frame: frame,
          source: source,
          currentState: state,
        );
      case Rule rule:
        var resolvedCall = _resolveParameterCallArguments(
          action.targetParameter,
          action.arguments,
          frame,
          rule,
        );
        if (resolvedCall == null) {
          return;
        }
        _seedRuleCall(
          targetRule: rule,
          callArguments: resolvedCall.arguments,
          callArgumentsKey: resolvedCall.key,
          action: action,
          returnState: action.nextState,
          minPrecedenceLevel: action.minPrecedenceLevel,
          frame: frame,
          source: source,
          currentState: state,
        );
      default:
        throw UnsupportedError(
          "Unsupported parameter call value for ${action.targetParameter}: ${value.runtimeType}",
        );
    }
  }

  /// Processes a [ParameterPredicateAction], initiating a lookahead on a parameter.
  void _processParameterPredicateAction(Frame frame, State state, ParameterPredicateAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.name)) {
      throw StateError("Missing argument '${action.name}' for parameter reference.");
    }

    var value = arguments[action.name];
    switch (value) {
      case String text:
        if (text.isEmpty) {
          if (action.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: -1,
              branchKey: ActionBranchKey(action),
            );
          }
          return;
        }

        const predicateSymbol = -1;
        _handlePredicate(
          symbol: predicateSymbol,
          frame: frame,
          isAnd: action.isAnd,
          source: source,
          nextState: action.nextState,
          name: action.name,
          action: action,
        );

      case Rule rule:
      case RuleCall(rule: var rule):
        if (value is RuleCall && value.arguments.isNotEmpty) {
          throw UnsupportedError(
            "Parameterized call objects are not supported in predicates yet: "
            "${value.rule.name.symbol}",
          );
        }

        var symbol = rule.symbolId;
        if (symbol == null) {
          throw StateError("Predicate rule must have a symbol id.");
        }

        _handlePredicate(
          symbol: symbol,
          frame: frame,
          isAnd: action.isAnd,
          source: source,
          nextState: action.nextState,
          name: action.name,
          action: action,
        );

      case Eps():
        if (action.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: frame.context,
            parentMarks: frame.marks,
            nextState: action.nextState,
            isAnd: action.isAnd,
            symbol: -1,
            branchKey: ActionBranchKey(action),
          );
        }
      case Pattern pattern when pattern.singleToken():
        var matches = token != null && pattern.match(token);
        if (matches == action.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: frame.context,
            parentMarks: frame.marks,
            nextState: action.nextState,
            isAnd: action.isAnd,
            symbol: -1,
            branchKey: ActionBranchKey(action),
          );
        }
      case bool matches:
        if (matches == action.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: frame.context,
            parentMarks: frame.marks,
            nextState: action.nextState,
            isAnd: action.isAnd,
            symbol: -1,
            branchKey: ActionBranchKey(action),
          );
        }
      case Pattern pattern:
        throw UnsupportedError(
          "Complex parser objects used as parameter predicates are not supported yet: ${pattern.runtimeType}",
        );
    }
  }

  /// Processes a [TailCallAction], performing tail-call optimization.
  ///
  /// This method resolves arguments and checks guards, then jumps directly into
  /// the rule's entry state using the [_tailCallTrampoline].
  void _processTailCallAction(Frame frame, State state, TailCallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    var targetRule = parseState.rulesById[action.ruleSymbol]!;
    var resolvedCall = _resolveCallArgumentValues(action.arguments, frame, targetRule);
    if (!_ruleGuardPasses(
      targetRule,
      frame,
      arguments: resolvedCall.arguments,
      argumentsKey: resolvedCall.key,
    )) {
      return;
    }

    var firstState = parseState.parser.stateMachine.ruleFirst[action.ruleSymbol];
    if (firstState != null) {
      var tailContext = frame.context.copyWith(
        position: position,
        minPrecedenceLevel: action.minPrecedenceLevel,
        arguments: resolvedCall.arguments,
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
        var targetRule = parseState.rulesById[tailCall.ruleSymbol]!;
        var resolvedCall = _resolveCallArgumentValues(
          tailCall.arguments,
          Frame(context, marks),
          targetRule,
        );

        if (!_ruleGuardPasses(
          targetRule,
          Frame(context, marks),
          arguments: resolvedCall.arguments,
          argumentsKey: resolvedCall.key,
        )) {
          return;
        }

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
  /// predicate and conjunction trackers. For rule calls, it records the result
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
      var key = PredicateKey(
        caller.pattern,
        caller.startPosition,
        isAnd: caller.isAnd,
        name: caller.name,
      );
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

      for (var (source, parentContext, nextState, parentMarks) in tracker.waiters) {
        parseState.decrementTrackers(parentContext, "childMatched");

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
    }

    if (caller is ConjunctionCallerKey) {
      var key = ConjunctionKey(caller.left, caller.right, caller.startPosition);
      var tracker = parseState.trackers[key];
      if (tracker is ConjunctionTracker) {
        _finishConjunction(tracker, returnPosition, caller.isLeft, frame.marks);
      }
      return;
    }

    if (!isSupportingAmbiguity && !_returnedCallersPositionAware.add((caller, returnPosition))) {
      return;
    }

    if (caller is Caller) {
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
            parentMarks.value,
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
