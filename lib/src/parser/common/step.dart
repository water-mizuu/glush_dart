/// Core parser utilities and data structures for the Glush Dart parser.
import "dart:collection";

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/helper/ref.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/label_capture.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/branch_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/key/context_key.dart";
import "package:glush/src/parser/key/guard_cache_key.dart";
import "package:glush/src/parser/key/return_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// Single parsing step at one input position.
///
/// A [Step] coordinates the exploration of all reachable states at a single
/// input position (see [position]). It manages:
/// - The work queue for exploring states at the current [position]
/// - Deduplication of equivalent parsing contexts
/// - Branching and result merging for ambiguous paths
/// - Requeueing frames that may have lagging [Context.position]s
///
/// NOTE: The [position] here is distinct from [Context.position].
/// A frame can be "lagging": at Step position 10 but its parse has only
/// advanced to position 7. Such frames replay historical tokens
/// using [ParseState.historyByPosition] to catch up.
class Step {
  Step(
    this.parseState,
    this.token,
    this.position, {
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
  });

  /// The global parse session state.
  final ParseState parseState;

  /// The current input token being processed (null at end-of-input).
  final int? token;

  /// The current zero-based input position being processed by this step.
  ///
  /// This is distinct from [Context.position]:
  /// - [position]: where the parser is NOW (advances as tokens are consumed)
  /// - [Context.position]: how far a specific parse path has advanced
  ///   (may lag behind if the frame is replaying historical input)
  final int position;

  /// Whether to support ambiguous parse paths (forest mode).
  final bool isSupportingAmbiguity;

  /// Whether to capture exact tokens as marks.
  final bool captureTokensAsMarks;

  /// Frames produced for the *next* input position after consuming a token.
  final List<Frame> nextFrames = [];

  /// Batched current-position frames grouped by context metadata.
  final Map<int, ContextGroup> _currentFrameGroupsInt = {};
  final Map<ComplexContextKey, ContextGroup> _currentFrameGroupsComplex = {};

  /// Batched next-position frames grouped by context metadata.
  final Map<int, ContextGroup> _nextFrameGroupsInt = {};
  final Map<ComplexContextKey, ContextGroup> _nextFrameGroupsComplex = {};

  /// Deduplication set for non-forest mode.
  final Set<int> _activeContextKeysInt = {};
  final Set<ComplexContextKey> _activeContextKeysComplex = {};

  /// The work queue for same-position closure exploration.
  final Queue<(ContextKey, State)> _workQueue = DoubleLinkedQueue();

  /// Set of GSS callers that have already returned at this position.
  final Set<CallerKey> _returnedCallers = {};

  /// Deduplication set for uniquely identifying accepted parse contexts and their marks.
  final Map<Context, LazyGlushList<Mark>> acceptedContexts = {};

  /// Frames that were delayed or diverted (e.g. for sub-parses).
  final List<Frame> requeued = [];

  /// Cache for guard evaluation results within this execution step.
  final Map<GuardCacheKey, bool> _guardResultCache = {};

  /// Requeue work for processing at a future step position.
  ///
  /// Frames with [Context.position] different from [position]
  /// are deferred to later processing using the parser's work queue. This keeps
  /// parsing position-ordered: same-position closure is completed before
  /// processing frames that lag behind (frames from sub-parses, predicates, etc.).
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
      var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
      var tracker = parseState.predicateTrackers[key];
      tracker?.addPendingFrame();
      if (tracker != null) {
        parseState.tracer.onTrackerUpdate(
          "Predicate",
          tracker.toString(),
          tracker.activeFrames,
          "requeue",
        );
      }
    }

    if (frame.context.caller case ConjunctionCallerKey caller) {
      var key = ConjunctionKey(caller.left, caller.right, caller.startPosition);
      var tracker = parseState.conjunctionTrackers[key];
      tracker?.addPendingFrame();
      if (tracker != null) {
        parseState.tracer.onTrackerUpdate(
          "Conjunction",
          tracker.toString(),
          tracker.activeFrames,
          "requeue",
        );
      }
    }
  }

  /// Resolve a conjunction match and wake up any waiters at the matching position.
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

  void _triggerConjunctionReturn(
    ConjunctionTracker tracker,
    int endPosition,
    LazyGlushList<Mark> left,
    LazyGlushList<Mark> right,
    List<(ParseNodeKey? source, Context, State, LazyGlushList<Mark>)> targetWaiters,
  ) {
    // Create a Parallel node representing the cartesian product of left and right marks
    // at the same span. This captures all combinations of parallel marks.
    var conjunctionResult = LazyGlushList.conjunction(left, right);

    for (var (_, parentContext, nextState, parentMarks) in targetWaiters) {
      // Add the parallel result to the parent marks.
      var nextMarks = parentMarks.addList(conjunctionResult);
      var nextContext = parentContext.advancePosition(endPosition);

      requeue(Frame(nextContext, nextMarks)..nextStates.add(nextState));
    }
  }

  /// Resume a continuation that was parked behind a predicate.
  ///
  /// The frame is requeued at the original parent position so it can catch up
  /// through already-seen input using the parser's token history, just like an
  /// epsilon transition reopening a delayed path.
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

    parseState.tracer.onPredicateResumed(symbol, position, isAnd: isAnd);

    requeue(Frame(parentContext, marks)..nextStates.add(nextState));
  }

  /// Seed a predicate sub-parse at the current input position.
  ///
  /// Predicates are lookahead-only, so their entry states are spawned in a
  /// separate sub-parse that can resolve later and wake parked continuations.
  void _spawnPredicateSubparse(PatternSymbol symbol, Frame frame) {
    var entryState = parseState.parser.stateMachine.ruleFirst[symbol];
    // Missing entry states indicates invalid predicate target symbol.
    if (entryState == null) {
      // Predicates must map to rule entries in the state machine.
      throw StateError("Predicate symbol must resolve to a rule: $symbol");
    }
    var predicateKey = PredicateCallerKey(symbol, position);
    var nextStack = frame.context.predicateStack.add(predicateKey);

    parseState.tracer.onMessage("Spawning sub-parse for predicate: $symbol");

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
  void _spawnConjunctionSubparse(PatternSymbol left, PatternSymbol right, Frame frame) {
    var leftState = parseState.parser.stateMachine.ruleFirst[left];
    var rightState = parseState.parser.stateMachine.ruleFirst[right];

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
    parseState.conjunctionTrackers[subParseKey]!; // Touch to ensure it exists if called from Action

    // Side A
    if (leftState case var s?) {
      _enqueue(
        s,
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
    if (rightState case var s?) {
      _enqueue(
        s,
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

  /// Seed a negation sub-parse at the current input position.
  void _spawnNegationSubparse(PatternSymbol symbol, Frame frame) {
    var entryState = parseState.parser.stateMachine.ruleFirst[symbol];
    // Missing entry states indicates invalid negation target symbol.
    if (entryState == null) {
      // Negations must map to rule entries in the state machine.
      throw StateError("Negation symbol must resolve to a rule: $symbol");
    }
    var newNegationKey = NegationCallerKey(symbol, position);

    _enqueue(
      entryState,
      Context(
        newNegationKey,
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        callStart: position,
        position: position,
        predicateStack: frame.context.predicateStack, // Negations inherit parent predicate stack
      ),
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
  int? _getTokenFor(Frame frame) {
    var framePos = frame.context.position;
    // Frame already at this step's current position: use current token directly.
    if (framePos == position) {
      return token;
    }
    // Frame is lagging: pull token from shared history.
    return parseState.historyByPosition[framePos];
  }

  /// Evaluates whether a rule's guard expression allows expansion in the current context.
  ///
  /// Guards are used to enforce semantic constraints or custom dispatch logic.
  bool _ruleGuardPasses(
    Rule rule,
    Frame frame, {
    required Map<String, Object?> arguments,
    required CallArgumentsKey argumentsKey,
  }) {
    var guard = rule.guard;
    // If no guard is defined, the rule always passes.
    if (guard == null) {
      return true;
    }

    // Guard results are cached by rule, position, arguments, and mark forest so
    // repeated branches do not re-evaluate the same boolean expression.
    var subjectRule = rule.guardOwner ?? rule;
    var cacheKey = GuardCacheKey(
      subjectRule,
      guard,
      argumentsKey,
      position,
      frame.context.callStart,
      frame.context.minPrecedenceLevel,
    );

    if (_guardResultCache.containsKey(cacheKey)) {
      GlushProfiler.incrementHit("parser.guard.cache");
      return _guardResultCache[cacheKey]!;
    }

    GlushProfiler.incrementMiss("parser.guard.cache");
    var result = GlushProfiler.measure("parser.guard.evaluate", () {
      return guard.evaluate(
        _buildGuardEnvironment(rule: subjectRule, frame: frame, arguments: arguments),
      );
    });
    _guardResultCache[cacheKey] = result;
    GlushProfiler.increment("parser.guard.cache_assign");
    return result;
  }

  GuardEnvironment _buildGuardEnvironment({
    required Rule rule,
    required Frame frame,
    required Map<String, Object?> arguments,
  }) {
    // Guards only need a small semantic snapshot: the active rule, the parser
    // position, caller arguments, and lazy access to marks/captures.
    var values = <String, Object?>{
      "rule": rule,
      "ruleName": rule.name.symbol,
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
        ruleName: rule.name.symbol,
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

  CaptureValue? _extractLabelCapture(LazyGlushList<Mark> marks, String target) {
    var concreteMarks = marks.evaluate();
    var cacheKey = (concreteMarks, target);
    if (parseState.labelCaptureCache.containsKey(cacheKey)) {
      GlushProfiler.incrementHit("parser.capture.cache");
      return parseState.labelCaptureCache[cacheKey];
    }
    GlushProfiler.incrementMiss("parser.capture.cache");

    // If multiple branches can produce the same capture name, we keep the
    // earliest capture as the canonical one for this forest.
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
    parseState.labelCaptureCache[cacheKey] = capture;
    GlushProfiler.increment("parser.capture.cache_assign");
    return capture;
  }

  String _captureText(int startPosition, int endPosition) {
    GlushProfiler.increment("parser.capture.text_rebuilds");
    var buffer = StringBuffer();
    for (var i = startPosition; i < endPosition; i++) {
      var unit = parseState.historyByPosition[i];

      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

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

    // Ensure deterministic ordering for the composite key
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
    // Rule guards are checked before the callee is spawned, so failed guards
    // never allocate a caller node or enter the callee state machine.
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
    if (isNewCaller) {
      parseState.tracer.onRuleCall(targetRule, position, caller);
      var firstState = parseState.parser.stateMachine.ruleFirst[targetRule.symbolId];

      if (firstState != null) {
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

  void _spawnParameterPredicateSubparse({
    required String text,
    required Frame frame,
    required bool isAnd,
  }) {
    var entryState = parseState.parser.stateMachine.parameterPredicateEntry(text);
    var syntheticSymbol = PatternSymbol("_param_${isAnd ? 'and' : 'not'}_$text");
    var newPredicateKey = PredicateCallerKey(syntheticSymbol, position);
    var nextStack = frame.context.predicateStack.add(newPredicateKey);

    _enqueue(
      entryState,
      Context(
        newPredicateKey,
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        predicateStack: nextStack,
        callStart: position,
        position: position,
      ),
      const LazyGlushList<Mark>.empty(),
    );
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
  void _enqueue(
    State state,
    Context context,
    LazyGlushList<Mark> marks, {
    ParseNodeKey? source,
    StateAction? action,
    ParseNodeKey? callSite,
  }) {
    GlushProfiler.increment("parser.enqueue.calls");
    var nextContext = context;

    var targetPosition = nextContext.position;
    // If frame's position != current position, defer it for later.
    // This keeps parsing position-ordered (same-position closure first).
    if (targetPosition != position) {
      // Frame is lagging and will be processed when its position comes up.
      GlushProfiler.increment("parser.enqueue.requeued");
      parseState.tracer.onEnqueue(state, targetPosition, "future position");
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

      _workQueue.add((IntContextKey(packedId), state));
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

    if (nextContext.predicateStack.lastOrNull case var pk?) {
      var pKey = PredicateKey(pk.pattern, pk.startPosition);
      var tracker = parseState.predicateTrackers[pKey];
      tracker?.addPendingFrame();
      if (tracker != null) {
        parseState.tracer.onTrackerUpdate(
          "Predicate",
          tracker.toString(),
          tracker.activeFrames,
          "enqueue",
        );
      }
    }
    if (nextContext.caller case ConjunctionCallerKey con) {
      var key = ConjunctionKey(con.left, con.right, con.startPosition);
      var tracker = parseState.conjunctionTrackers[key];
      tracker?.addPendingFrame();
      if (tracker != null) {
        parseState.tracer.onTrackerUpdate(
          "Conjunction",
          tracker.toString(),
          tracker.activeFrames,
          "enqueue",
        );
      }
    }

    // Initialize group and store initial marks.
    _currentFrameGroupsComplex[key] = ContextGroup(state, nextContext)..addMarks(marks);
    _workQueue.add((key, state));
  }

  /// Execute outgoing actions for one `(frame,state)` pair.
  ///
  /// Token-consuming actions are batched into `_nextFrameGroups` and finalized
  /// together in [finalize], while zero-width actions (epsilon transitions)
  /// are enqueued immediately. This split avoids interleaving same-position
  /// closure with next-position work.
  void _process(Frame frame, State state) {
    // Iterate over all possible actions originating from the current state.
    for (var action in state.actions) {
      parseState.tracer.onAction(action, "processing");
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
        case BackreferenceAction():
          _processBackreferenceAction(frame, state, action);
        case PredicateAction():
          _processPredicateAction(frame, state, action);
        case ConjunctionAction():
          _processConjunctionAction(frame, state, action);
        case NegationAction():
          _processNegationAction(frame, state, action);
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
      parseState.tracer.onRuleReturn(caller.rule, position, caller);
      return;
    }
    parseState.tracer.onRuleReturn(caller.rule, position, caller);

    var packedId = ReturnKey.getPackedId(
      returnContext.precedenceLevel,
      returnContext.position,
      returnContext.callStart,
    );

    // Use a LazyReturn proxy to represent the (potentially evolving) results of the rule.
    var returnProxy = caller.getLazyReturnProxy(packedId, () => caller.getReturnMarks(packedId));

    // Fast paths for the common case where one/both mark streams are empty.
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
  void finalize() {
    for (var nextGroup in _nextFrameGroupsInt.values) {
      _processNextGroup(nextGroup);
    }
    for (var nextGroup in _nextFrameGroupsComplex.values) {
      _processNextGroup(nextGroup);
    }
    _nextFrameGroupsInt.clear();
    _nextFrameGroupsComplex.clear();
  }

  void _processNextGroup(ContextGroup nextGroup) {
    var branchedMarks = nextGroup.mergedMarks;
    var context = nextGroup.context;
    var caller = context.caller;
    var callerStartPosition = caller.startPosition;

    if (context.position != position + 1 || context.callStart != callerStartPosition) {
      context = context.copyWith(position: position + 1, callStart: callerStartPosition);
    }

    var nextFrame = Frame(context, branchedMarks);
    nextFrame.nextStates.add(nextGroup.state);

    if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
      var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
      var tracker = parseState.predicateTrackers[key];
      if (tracker != null) {
        tracker.addPendingFrame();
      }
    }

    nextFrames.add(nextFrame);
  }

  /// Compute the same-position closure for a given frame.
  ///
  /// This method explores all epsilon transitions departing from the frame's
  /// entry state. In ambiguity mode, distinct mark branches are tracked.
  void processFrame(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      parseState.tracer.onProcessState(frame, state);
      _enqueue(state, frame.context, frame.marks);
    }
    while (_workQueue.isNotEmpty) {
      var (key, state) = _workQueue.removeFirst();
      ContextGroup? group;
      if (key is IntContextKey) {
        group = _currentFrameGroupsInt.remove(key.id);
      } else {
        group = _currentFrameGroupsComplex.remove(key as ComplexContextKey);
      }

      if (group == null) {
        continue;
      }

      var marks = group.mergedMarks;
      var context = group.context;

      if (context.predicateStack.lastOrNull case var pk?) {
        var pKey = PredicateKey(pk.pattern, pk.startPosition);
        var tracker = parseState.predicateTrackers[pKey];
        if (tracker != null) {
          tracker.removePendingFrame();
          parseState.tracer.onTrackerUpdate(
            "Predicate",
            tracker.toString(),
            tracker.activeFrames,
            "process",
          );
        }
      }
      if (context.caller case ConjunctionCallerKey c) {
        var key = ConjunctionKey(c.left, c.right, c.startPosition);
        var tracker = parseState.conjunctionTrackers[key];
        if (tracker != null && tracker.activeFrames > 0) {
          tracker.removePendingFrame();
          parseState.tracer.onTrackerUpdate(
            "Conjunction",
            tracker.toString(),
            tracker.activeFrames,
            "process",
          );
        }
      }

      if (context.caller case NegationCallerKey caller) {
        parseState
            .negationTrackers[NegationKey(caller.pattern, caller.startPosition)]
            ?.visitedPositions
            .add(position);
      }
      _enqueue(state, context, marks);
    }
  }

  /// Enqueue a frame without processing the work queue.
  /// Use this with processFrameFinalize() for batching.
  void processFrameEnqueue(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      parseState.tracer.onProcessState(frame, state);
      _enqueue(state, frame.context, frame.marks);
    }
  }

  /// Process all accumulated work from previous processFrameEnqueue() calls.
  /// This must be called after all frames at a position have been enqueued.
  void processFrameFinalize() {
    while (_workQueue.isNotEmpty) {
      var (key, state) = _workQueue.removeFirst();
      ContextGroup? group;
      if (key is IntContextKey) {
        group = _currentFrameGroupsInt.remove(key.id);
      } else {
        group = _currentFrameGroupsComplex.remove(key as ComplexContextKey);
      }
      if (group == null) {
        continue;
      }

      var marks = group.mergedMarks;
      var context = group.context;

      if (context.predicateStack.lastOrNull case var pk?) {
        var pKey = PredicateKey(pk.pattern, pk.startPosition);
        var tracker = parseState.predicateTrackers[pKey];
        if (tracker != null) {
          tracker.removePendingFrame();
          parseState.tracer.onTrackerUpdate(
            "Predicate",
            tracker.toString(),
            tracker.activeFrames,
            "processBatch",
          );
        }
      }
      if (context.caller case ConjunctionCallerKey c) {
        var key = ConjunctionKey(c.left, c.right, c.startPosition);
        var tracker = parseState.conjunctionTrackers[key];
        if (tracker != null && tracker.activeFrames > 0) {
          tracker.removePendingFrame();
          parseState.tracer.onTrackerUpdate(
            "Conjunction",
            tracker.toString(),
            tracker.activeFrames,
            "processBatch",
          );
        }
      }

      if (context.caller case NegationCallerKey caller) {
        parseState
            .negationTrackers[NegationKey(caller.pattern, caller.startPosition)]
            ?.visitedPositions
            .add(position);
      }

      _process(Frame(context, marks), state);
    }
  }

  // ============================================================================
  // StateAction Processing Methods
  // ============================================================================
  // The following private methods handle the logic for each StateAction type.
  // They are extracted from the _process method for readability and maintainability.

  /// Handle [TokenAction]: consume a token matching the expected pattern.
  void _processTokenAction(Frame frame, State state, TokenAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);

    // Token actions fire only when an input token matches the expected pattern.
    if (token != null && action.choice.matches(token)) {
      var newMarks = frame.marks;
      var pattern = action.choice;

      // Terminal capture logic: some patterns (like literal strings)
      // naturally want to be captured as marks.
      var shouldCapture = captureTokensAsMarks || (pattern is Token && pattern.capturesAsMark);

      // Capture policy controls whether consumed chars become human-readable StringMarks.
      if (shouldCapture) {
        newMarks = newMarks.add(StringMarkVal(String.fromCharCode(token), position));
      }

      // BATTERIZED next-position fast path calculation
      if (frameContext.predicateStack.isEmpty &&
          frameContext.captures.isEmpty &&
          frameContext.arguments.isEmpty) {
        var packedId =
            (frameContext.caller.uid << 32) |
            (action.nextState.id << 8) |
            (frameContext.minPrecedenceLevel ?? 0xFF);
        var nextGroup = _nextFrameGroupsInt[packedId];
        if (nextGroup != null) {
          nextGroup.addMarks(newMarks);
        } else {
          _nextFrameGroupsInt[packedId] = ContextGroup(
            action.nextState,
            frameContext.advancePosition(position + 1),
          )..addMarks(newMarks);
        }
      } else {
        var complexKey = ComplexContextKey(
          action.nextState,
          frameContext.advancePosition(position + 1),
        );
        var nextGroup = _nextFrameGroupsComplex[complexKey];
        if (nextGroup != null) {
          nextGroup.addMarks(newMarks);
        } else {
          _nextFrameGroupsComplex[complexKey] = ContextGroup(
            action.nextState,
            frameContext.advancePosition(position + 1),
          )..addMarks(newMarks);
        }
      }
    }
  }

  /// Handle [BoundaryAction]: check start-of-input or end-of-input conditions.
  void _processBoundaryAction(Frame frame, State state, BoundaryAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    // Boundary actions match either the start-of-input (position 0)
    // or end-of-input (token is null).
    var isMatch = action.kind == BoundaryKind.start ? position == 0 : token == null;
    if (isMatch) {
      _enqueue(action.nextState, frameContext, frame.marks, source: source, action: action);
    }
  }

  /// Handle [ParameterStringAction]: consume a specific code unit.
  void _processParameterStringAction(Frame frame, State state, ParameterStringAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);

    if (token != null && token == action.codeUnit) {
      var newMarks = frame.marks;
      if (captureTokensAsMarks) {
        newMarks = newMarks.add(StringMarkVal(String.fromCharCode(action.codeUnit), position));
      }

      // BATTERIZED next-position fast path calculation
      if (frameContext.predicateStack.isEmpty &&
          frameContext.captures.isEmpty &&
          frameContext.arguments.isEmpty) {
        var packedId =
            (frameContext.caller.uid << 32) |
            (action.nextState.id << 8) |
            (frameContext.minPrecedenceLevel ?? 0xFF);
        var nextGroup = _nextFrameGroupsInt[packedId];
        if (nextGroup != null) {
          GlushProfiler.incrementHit("parser.context.dedup");
        } else {
          GlushProfiler.incrementMiss("parser.context.dedup");
          nextGroup = _nextFrameGroupsInt[packedId] = ContextGroup(
            action.nextState,
            frameContext.advancePosition(position + 1),
          );
        }
        nextGroup.addMarks(newMarks);
      } else {
        var complexKey = ComplexContextKey(
          action.nextState,
          frameContext.advancePosition(position + 1),
        );
        var nextGroup = _nextFrameGroupsComplex[complexKey];
        if (nextGroup != null) {
          GlushProfiler.incrementHit("parser.context.dedup");
        } else {
          GlushProfiler.incrementMiss("parser.context.dedup");
          nextGroup = _nextFrameGroupsComplex[complexKey] = ContextGroup(
            action.nextState,
            frameContext.advancePosition(position + 1),
          );
        }
        nextGroup.addMarks(newMarks);
      }
    }
  }

  /// Handle [MarkAction]: emit a named mark at the current position.
  void _processMarkAction(Frame frame, State state, MarkAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    // Emit a named mark at the current position.
    // Used for user-defined annotations.
    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(NamedMarkVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Handle [LabelStartAction]: begin a labeled capture group.
  void _processLabelStartAction(Frame frame, State state, LabelStartAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    // Begin a labelled span (capture start).
    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(LabelStartVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Handle [LabelEndAction]: end a labeled capture group.
  void _processLabelEndAction(Frame frame, State state, LabelEndAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    // End a labelled span (capture end).
    // This allows the parser to extract the text covered by the label.
    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(LabelEndVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Handle [BackreferenceAction]: create an expanding mark for backref.
  void _processBackreferenceAction(Frame frame, State state, BackreferenceAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);

    _enqueue(
      action.nextState,
      frameContext,
      frame.marks.add(ExpandingMarkVal(action.name, position)),
      source: source,
      action: action,
    );
  }

  /// Handle [PredicateAction]: lookahead predicate (&pattern or !pattern).
  void _processPredicateAction(Frame frame, State state, PredicateAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Lookahead predicate (&pattern or !pattern).
    // Spawns a sub-parse that must complete before this path can continue.
    var symbol = action.symbol;
    var subParseKey = PredicateKey(symbol, position);
    var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);

    // Use a tracker to coordinate results from the sub-parse.
    var tracker = parseState.predicateTrackers[subParseKey] ??= PredicateTracker(
      symbol,
      position,
      isAnd: action.isAnd,
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
      // AND can resume once with the current results.
      if (tracker.isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: action.nextState,
          isAnd: action.isAnd,
          symbol: action.symbol,
          branchKey: ActionBranchKey(action),
        );
      }
    }

    if (!tracker.exhausted) {
      // Still active; park continuation to catch future (potentially longer) matches.
      tracker.waiters.add((source, frameContext, action.nextState, frame.marks));

      var predicateKey = frameContext.predicateStack.lastOrNull;
      if (predicateKey != null) {
        // Register dependency: the parent predicate depends on this child's completion.
        var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
        parseState.predicateTrackers[key]?.addPendingFrame();
      }
    } else if (tracker.canResolveFalse) {
      // The sub-parse already exhausted without matching; NOT waiters resume.
      if (!tracker.isAnd) {
        _resumeLaggedPredicateContinuation(
          source: source,
          parentContext: frame.context,
          parentMarks: frame.marks,
          nextState: action.nextState,
          isAnd: action.isAnd,
          symbol: action.symbol,
          branchKey: ActionBranchKey(action),
        );
      }
    }

    // Seed the sub-parse if this is the first time we've reached this predicate.
    if (isFirst && !tracker.matched && !tracker.exhausted) {
      _spawnPredicateSubparse(symbol, frame);
    }
  }

  /// Handle [ConjunctionAction]: intersection rule (A & B).
  void _processConjunctionAction(Frame frame, State state, ConjunctionAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Intersection rule (A & B).
    // Both side A and side B are run independently from the same position.
    var left = action.leftSymbol;
    var right = action.rightSymbol;
    var key = ConjunctionKey(left, right, position);
    var isFirst = !parseState.conjunctionTrackers.containsKey(key);
    var tracker = parseState.conjunctionTrackers[key] ??= ConjunctionTracker(
      leftSymbol: left,
      rightSymbol: right,
      startPosition: position,
    );

    // Park the continuation until both sides meet at the same end position.
    var waiter = (source, frameContext, action.nextState, frame.marks);
    tracker.waiters.add(waiter);

    // Rendezvous logic: if results are already available for both sides
    // at some position J, resume the waiter immediately.
    for (var j in tracker.leftCompletions.keys) {
      if (tracker.rightCompletions.containsKey(j)) {
        var lefts = tracker.leftCompletions[j]!;
        var rights = tracker.rightCompletions[j]!;
        for (var left in lefts) {
          for (var right in rights) {
            _triggerConjunctionReturn(tracker, j, left, right, [waiter]);
          }
        }
      }
    }

    if (isFirst) {
      _spawnConjunctionSubparse(left, right, frame);
    }
  }

  /// Handle [NegationAction]: negative lookahead (!pattern).
  void _processNegationAction(Frame frame, State state, NegationAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Negative lookahead (!pattern).
    // Continues only if the sub-parse fails to match a given span.
    var symbol = action.symbol;
    var key = NegationKey(symbol, position);
    var isFirst = !parseState.negationTrackers.containsKey(key);
    var tracker = parseState.negationTrackers[key] ??= NegationTracker(symbol, position);

    // Probing: If a position is already set, we check if [start, position] matches.
    var targetJ = frame.context.position;
    if (tracker.matchedPositions.contains(targetJ)) {
      // The sub-parse already matched this specific span, so negation fails.
    } else if (tracker.isExhausted) {
      // The child sub-parse is done and did NOT match targetJ; negation succeeds.
      _resumeLaggedPredicateContinuation(
        source: source,
        parentContext: frame.context,
        parentMarks: frame.marks,
        nextState: action.nextState,
        isAnd: true,
        symbol: action.symbol,
        branchKey: ActionBranchKey(action),
      );
    } else if (!tracker.hasWaiterAt(targetJ)) {
      // Result unknown; park until sub-parse settles for this j.
      tracker.addWaiter(targetJ, (frameContext, action.nextState, frame.marks));
    }

    if (isFirst) {
      _spawnNegationSubparse(symbol, frame);
    }
  }

  /// Handle [CallAction]: static rule call (GLL).
  void _processCallAction(Frame frame, State state, CallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Static rule call (GLL).
    // Resolves arguments and initiates rule expansion via GSS.
    var targetRule = parseState.rulesByName[action.ruleSymbol.symbol]!;
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

  /// Handle [ParameterAction]: dynamic parameter reference ($paramName).
  void _processParameterAction(Frame frame, State state, ParameterAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Dynamic parameter reference ($paramName).
    // Resolves the parameter value from the caller's environment.
    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.name)) {
      throw StateError("Missing argument '${action.name}' for parameter reference.");
    }

    var value = arguments[action.name];
    switch (value) {
      case String text:
        // String parameters are materialized as virtual input tokens.
        if (text.isEmpty) {
          // Epsilon transition if the string is empty.
          _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
          return;
        }
        // Redirect to a synthetic state machine that consumes the string.
        var entryState = parseState.parser.stateMachine.parameterStringEntry(
          text,
          action.nextState,
        );
        _enqueue(entryState, frame.context, frame.marks, source: source, action: action);
        return;
      case CaptureValue captureValue:
        // Data captured from a label can also be used as a parameter.
        var entryState = parseState.parser.stateMachine.parameterStringEntry(
          captureValue.value,
          action.nextState,
        );
        _enqueue(entryState, frame.context, frame.marks, source: source, action: action);
      case RuleCall callValue:
        // Parameter resolves to a rule call: expansion occurs at the current position.
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
        // Parameter is a raw rule reference.
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
        // Parameter as epsilon transition.
        _enqueue(action.nextState, frame.context, frame.marks, source: source, action: action);
      case Pattern pattern when pattern.singleToken():
        // Parameter as a single-token pattern (e.g. char ranges).
        if (token != null && pattern.match(token)) {
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

  /// Handle [ParameterCallAction]: rule call via parameter reference.
  void _processParameterCallAction(Frame frame, State state, ParameterCallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Rule call via a parameter reference ($paramName(args)).
    // Resolves the rule and merges call-site arguments with rule-defined ones.
    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.targetParameter)) {
      throw StateError("Missing argument '${action.targetParameter}' for parameter reference.");
    }

    var value = arguments[action.targetParameter];
    switch (value) {
      case RuleCall callValue:
        // Merge rule-provided arguments with the dynamic call-site arguments.
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
        // Parameter as a raw rule. We apply the call arguments to it.
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

  /// Handle [ParameterPredicateAction]: lookahead on dynamic parameter.
  void _processParameterPredicateAction(Frame frame, State state, ParameterPredicateAction action) {
    var frameContext = frame.context;
    var token = _getTokenFor(frame);
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Lookahead predicate on a dynamic parameter (&($paramName)).
    var arguments = frame.context.arguments;
    if (!arguments.containsKey(action.name)) {
      throw StateError("Missing argument '${action.name}' for parameter reference.");
    }

    var value = arguments[action.name];
    switch (value) {
      case String text:
        // Parameter predicates for strings reuse the same materialization logic
        // but wrap the result in lookahead (epsilon-like) semantics.
        if (text.isEmpty) {
          if (action.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_eps"),
              branchKey: ActionBranchKey(action),
            );
          }
          return;
        }
        var predicateSymbol = PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_$text");
        var subParseKey = PredicateKey(predicateSymbol, position);
        var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);
        var tracker = parseState.predicateTrackers[subParseKey] ??= PredicateTracker(
          predicateSymbol,
          position,
          isAnd: action.isAnd,
        );

        if (tracker.matched) {
          if (tracker.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: predicateSymbol,
              branchKey: ActionBranchKey(action),
            );
          }
        } else if (tracker.exhausted || (!isFirst && tracker.canResolveFalse)) {
          if (!tracker.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: predicateSymbol,
              branchKey: ActionBranchKey(action),
            );
          }
        } else {
          tracker.waiters.add((source, frameContext, action.nextState, frame.marks));
          var predicateKey = frameContext.predicateStack.lastOrNull;
          if (predicateKey != null) {
            var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
            var parentTracker = parseState.predicateTrackers[key];
            parentTracker?.addPendingFrame();
          }
        }

        if (isFirst && !tracker.matched && !tracker.exhausted) {
          // Seed a synthetic state machine to probe the parameter string.
          _spawnParameterPredicateSubparse(text: text, frame: frame, isAnd: action.isAnd);
        }
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

        var subParseKey = PredicateKey(symbol, position);
        var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);
        if (isFirst) {
          parseState.predicateTrackers[subParseKey] = PredicateTracker(
            symbol,
            position,
            isAnd: action.isAnd,
          );
        }
        var tracker = parseState.predicateTrackers[subParseKey]!;
        assert(
          tracker.isAnd == action.isAnd,
          "Invariant violation in ParameterPredicateAction: mixed AND/NOT trackers share "
          "the same parameter predicate key.",
        );

        if (tracker.matched) {
          if (tracker.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: symbol,
              branchKey: ActionBranchKey(action),
            );
          }
        }

        if (!tracker.exhausted) {
          tracker.waiters.add((source, frameContext, action.nextState, frame.marks));
          var predicateKey = frameContext.predicateStack.lastOrNull;
          if (predicateKey != null) {
            var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
            var parentTracker = parseState.predicateTrackers[key];
            parentTracker?.addPendingFrame();
          }
        } else if (tracker.canResolveFalse) {
          if (!tracker.isAnd) {
            _resumeLaggedPredicateContinuation(
              source: source,
              parentContext: frame.context,
              parentMarks: frame.marks,
              nextState: action.nextState,
              isAnd: action.isAnd,
              symbol: symbol,
              branchKey: ActionBranchKey(action),
            );
          }
        }

        if (isFirst && !tracker.matched && !tracker.exhausted) {
          _spawnPredicateSubparse(symbol, frame);
        }
      case Eps():
        if (action.isAnd) {
          _resumeLaggedPredicateContinuation(
            source: source,
            parentContext: frame.context,
            parentMarks: frame.marks,
            nextState: action.nextState,
            isAnd: action.isAnd,
            symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_eps"),
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
            symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_${pattern.runtimeType}"),
            branchKey: ActionBranchKey(action),
          );
        }
      case Pattern pattern:
        throw UnsupportedError(
          "Complex parser objects used as parameter predicates are not supported yet: ${pattern.runtimeType}",
        );
    }
  }

  /// Handle [TailCallAction]: tail-call optimized recursion.
  /// Uses direct trampolining to avoid queue overhead for recursive chains.
  void _processTailCallAction(Frame frame, State state, TailCallAction action) {
    var frameContext = frame.context;
    var source = ParseNodeKey(state.id, position, frameContext.caller);
    // Tail calls still respect argument resolution and guards, but avoid
    // allocating a fresh caller when the recursion can be looped.
    var targetRule = parseState.rulesByName[action.ruleSymbol.symbol]!;
    var resolvedCall = _resolveCallArgumentValues(action.arguments, frame, targetRule);
    if (!_ruleGuardPasses(
      targetRule,
      frame,
      arguments: resolvedCall.arguments,
      argumentsKey: resolvedCall.key,
    )) {
      return;
    }
    // Tail-call optimized recursion re-enters the rule without allocating
    // a fresh caller node. Use direct trampolining to avoid queue overhead.
    var firstState = parseState.parser.stateMachine.ruleFirst[action.ruleSymbol];
    if (firstState != null) {
      var tailContext = frame.context.copyWith(
        position: position,
        minPrecedenceLevel: action.minPrecedenceLevel,
        arguments: resolvedCall.arguments,
      );
      // Enter tail-call trampoline loop to process recursive chain directly
      _tailCallTrampoline(firstState, tailContext, frame.marks, source, action);
    }
  }

  /// Direct trampoline loop for tail calls.
  ///
  /// Processes tail calls in a loop without queue overhead, enabling efficient
  /// left-recursive and right-recursive parsing without stack growth or frame allocation.
  ///
  /// This replaces work-queue dequeue/enqueue for recursive chains, improving
  /// performance for deep recursion patterns.
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

    // Keep processing states in a loop until we hit a non-tail action
    while (true) {
      // Check for any non-tail actions that require work queue or deferred processing
      bool hasTailOnlyPath = true;
      TailCallAction? nextTailCall;

      for (var stateAction in state.actions) {
        if (stateAction case TailCallAction tailCall) {
          // Store potential tail call but check if there are other actions
          nextTailCall = tailCall;
        } else {
          // Any non-tail action means we need to exit trampoline and queue for normal processing
          hasTailOnlyPath = false;
          break;
        }
      }

      // If we found a pure tail call path, try to jump to next recursion level
      if (hasTailOnlyPath && nextTailCall != null && state.actions.length == 1) {
        // Single tail call action - jump to it directly
        var tailCall = nextTailCall;
        var targetRule = parseState.rulesByName[tailCall.ruleSymbol.symbol]!;
        var resolvedCall = _resolveCallArgumentValues(
          tailCall.arguments,
          Frame(context, marks),
          targetRule,
        );

        // Validate guard for the tail call
        if (!_ruleGuardPasses(
          targetRule,
          Frame(context, marks),
          arguments: resolvedCall.arguments,
          argumentsKey: resolvedCall.key,
        )) {
          return;
        }

        // Jump to the tail-called rule's entry state
        var nextFirstState = parseState.parser.stateMachine.ruleFirst[tailCall.ruleSymbol];
        if (nextFirstState == null) {
          return;
        }

        // Update state and context for next iteration
        state = nextFirstState;
        context = context.copyWith(
          position: position,
          minPrecedenceLevel: tailCall.minPrecedenceLevel,
        );
        // marks remain the same as tail calls don't consume tokens or emit marks themselves
        // (they just loop back)
        GlushProfiler.increment("parser.tail_call.trampoline_hop");
        continue; // Loop back to process next state
      }

      // Exit trampoline: process normally via work queue
      _enqueue(state, context, marks, source: source, action: action);
      return;
    }
  }

  /// Handle [ReturnAction]: return from a rule call.
  void _processReturnAction(Frame frame, State state, ReturnAction action) {
    // Enforce call-site precedence gating for this return.
    if (frame.context.minPrecedenceLevel != null &&
        action.precedenceLevel != null &&
        action.precedenceLevel! < frame.context.minPrecedenceLevel!) {
      // Returned precedence is below required minimum for this call-site.
      return;
    }

    var caller = frame.context.caller;

    // Predicate returns settle the predicate tracker directly.
    if (caller is PredicateCallerKey) {
      assert(
        frame.context.predicateStack.lastOrNull == caller,
        "Invariant violation in ReturnAction: predicate caller should be the top of predicateStack.",
      );
      var key = PredicateKey(caller.pattern, caller.startPosition);
      var tracker = parseState.predicateTrackers[key];
      if (tracker == null) {
        // The predicate may already have resolved in this position.
        return;
      }

      bool isNewLongest = tracker.longestMatch == null || position > tracker.longestMatch!;
      if (!isNewLongest) {
        return;
      }
      tracker.longestMatch = position;
      tracker.matched = true;

      for (var (source, parentContext, nextState, parentMarks) in tracker.waiters) {
        var predicateKey = parentContext.predicateStack.lastOrNull;
        if (predicateKey != null) {
          var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
          var parentTracker = parseState.predicateTrackers[key];
          if (parentTracker != null) {
            // This child branch is no longer pending in the parent predicate.
            parentTracker.removePendingFrame();
            parseState.tracer.onTrackerUpdate(
              "Predicate",
              parentTracker.toString(),
              parentTracker.activeFrames,
              "childMatched",
            );
          }
        }

        // AND predicates resume only on success.
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
      var tracker = parseState.conjunctionTrackers[key];
      if (tracker != null) {
        _finishConjunction(tracker, position, caller.isLeft, frame.marks);
      }
      return;
    }

    if (caller is NegationCallerKey) {
      var key = NegationKey(caller.pattern, caller.startPosition);
      var tracker = parseState.negationTrackers[key];
      if (tracker != null) {
        tracker.markMatchedPosition(position);
      }
      return;
    }

    // In single-derivation mode, replay each caller's returns once.
    if (!isSupportingAmbiguity && !_returnedCallers.add(caller)) {
      // Logical meaning:
      // - in single-derivation mode we replay returns once per caller key
      // - if add() is false, this caller was already replayed
      // => skip duplicate resume fan-out.
      return;
    }

    // Only caller nodes memoize return contexts and wake waiters.
    if (caller is Caller) {
      // Only rule-call callers memoize and replay return contexts.
      var returnContext = frame.context.copyWith(precedenceLevel: action.precedenceLevel);
      // Replay to waiters only when this return context is newly added.
      if (caller.addReturn(returnContext, frame.marks)) {
        // Newly discovered return context fan-outs to all queued waiters.
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
            source: ParseNodeKey(state.id, position, caller),
            action: action,
            callSite: callSite,
          );
        }
      }
    }
  }

  /// Handle [AcceptAction]: mark parse as accepted.
  void _processAcceptAction(Frame frame) {
    var previousMarks = acceptedContexts[frame.context];
    if (previousMarks != null) {
      acceptedContexts[frame.context] = LazyGlushList.branched(previousMarks, frame.marks);
    } else {
      acceptedContexts[frame.context] = frame.marks;
    }
  }
}
