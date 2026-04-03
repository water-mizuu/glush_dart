/// Core parser utilities and data structures for the Glush Dart parser.
import "dart:collection";

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/action_key.dart";
import "package:glush/src/parser/common/branch_key.dart";
import "package:glush/src/parser/common/caller_cache_key.dart";
import "package:glush/src/parser/common/caller_key.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/context_key.dart";
import "package:glush/src/parser/common/derivation_key.dart";
import "package:glush/src/parser/common/frame.dart";
import "package:glush/src/parser/common/guard_cache_key.dart";
import "package:glush/src/parser/common/label_capture.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/common/parse_state.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:glush/src/parser/common/trackers.dart";

/// Single parsing step at one input position.
///
/// A [Step] coordinates the exploration of all reachable states at a single
/// input position. it manages:
/// - The work queue for the current position
/// - Deduplication of equivalent parsing contexts
/// - Branching and result merging for ambiguous paths
/// - Requeueing frames that target different positions or pivots
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

  /// The current zero-based input position.
  final int position;

  /// Whether to support ambiguous parse paths (forest mode).
  final bool isSupportingAmbiguity;

  /// Whether to capture exact tokens as marks.
  final bool captureTokensAsMarks;

  /// Frames produced for the *next* input position after consuming a token.
  final List<Frame> nextFrames = [];

  /// Batched next-position frames grouped by context metadata.
  /// Keys can be `int` (packed) or [ComplexContextKey].
  final Map<ContextKey, ContextGroup> _nextFrameGroups = {};

  /// Batched current-position frames grouped by context metadata.
  /// Keys can be `int` (packed) or [ComplexContextKey].
  final Map<ContextKey, Context> _currentFrameGroups = {};

  /// Deduplication set for non-forest mode.
  /// Keys can be `int` (packed) or [ComplexContextKey].
  final Set<ContextKey> _activeContextKeys = {};

  /// The work queue for same-position closure exploration.
  final Queue<(ContextKey, State)> _workQueue = DoubleLinkedQueue();

  /// Set of GSS callers that have already returned at this position.
  final Set<CallerKey> _returnedCallers = {};

  /// Deduplication set for uniquely identifying accepted parse contexts.
  final Set<Context> acceptedContexts = {};

  /// Frames that were delayed or diverted (e.g. for sub-parses).
  final List<Frame> requeued = [];

  /// Cache for guard evaluation results within this execution step.
  final Map<GuardCacheKey, bool> _guardResultCache = {};

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
      var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
      parseState.predicateTrackers[key]?.addPendingFrame();
    }

    if (frame.context.caller case ConjunctionCallerKey caller) {
      parseState
          .conjunctionTrackers[ConjunctionKey(caller.left, caller.right, caller.startPosition)]
          ?.addPendingFrame();
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
    GlushList<Mark> left,
    GlushList<Mark> right,
    List<(ParseNodeKey? source, Context, State)> targetWaiters,
  ) {
    // Create a Parallel node representing the cartesian product of left and right marks
    // at the same span. This captures all combinations of parallel marks.
    var conjunctionResult = GlushList.conjunction(left, right);

    for (var (source, parentContext, nextState) in targetWaiters) {
      // Add the parallel result to the parent marks.
      var nextMarks = parentContext.marks.addList(conjunctionResult);
      var nextContext = parentContext.copyWith(pivot: endPosition, marks: nextMarks);

      if (isSupportingAmbiguity && source != null) {
        // Record the conjunction completion in the derivation path
        var nextPath = parentContext.derivationPath.add(
          DerivationKey(
            source,
            const ConjunctionBranchKey(), // Special marker for conjunction completion
            null,
          ),
        );
        nextContext = nextContext.copyWith(derivationPath: nextPath);
      }

      requeue(Frame(nextContext)..nextStates.add(nextState));
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
    BranchKey? branchKey,
  }) {
    var nextContext = parentContext;
    if (isSupportingAmbiguity && source != null) {
      var nextBranchKey =
          branchKey ??
          ActionBranchKey(PredicateAction(isAnd: isAnd, symbol: symbol, nextState: nextState));
      var nextPath = parentContext.derivationPath.add(DerivationKey(source, nextBranchKey, null));
      nextContext = parentContext.copyWith(derivationPath: nextPath);
    }

    parseState.tracer.onMessage("Predicate matched: $symbol (AND: $isAnd)");

    requeue(Frame(nextContext)..nextStates.add(nextState));
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
        const GlushList<Mark>.empty(),
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        predicateStack: nextStack,
        callStart: position,
        pivot: position,
      ),
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
          const GlushList<Mark>.empty(),
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          pivot: position,
          predicateStack: frame.context.predicateStack,
        ),
      );
    }

    // Side B
    if (rightState case var s?) {
      _enqueue(
        s,
        Context(
          rightCaller,
          const GlushList<Mark>.empty(),
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          pivot: position,
          predicateStack: frame.context.predicateStack,
        ),
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
        const GlushList<Mark>.empty(),
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        callStart: position,
        pivot: position,
        predicateStack: frame.context.predicateStack, // Negations inherit parent predicate stack
      ),
    );
  }

  /// Retrieves the correct token for a frame based on its pivot position.
  ///
  /// This allows lagging frames to catch up using the parser's shared token
  /// history, while current-position frames use the current token directly.
  int? _getTokenFor(Frame frame) {
    var framePos = frame.context.pivot ?? 0;
    // Frame already at this step's pivot: use current token directly.
    if (framePos == position) {
      return token;
    }
    // Otherwise pull token from shared history at the frame's pivot.
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
      frame.context.marks,
      argumentsKey,
      position,
      frame.context.callStart ?? position,
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
      "callStart": frame.context.callStart ?? position,
      "minPrecedenceLevel": frame.context.minPrecedenceLevel,
      "precedenceLevel": frame.context.precedenceLevel,
    };

    return GuardEnvironment(
      rule: rule,
      marks: frame.context.marks,
      arguments: arguments,
      values: values,
      valuesKey: GuardValuesKey(
        captureSignature: frame.context.captures.signature,
        ruleName: rule.name.symbol,
        position: position,
        callStart: frame.context.callStart ?? position,
        minPrecedenceLevel: frame.context.minPrecedenceLevel,
        precedenceLevel: frame.context.precedenceLevel,
      ),
      valueResolver: frame.context.captures.isEmpty ? null : (name) => frame.context.captures[name],
      captureResolver: _extractLabelCapture,
      rulesByName: parseState.rulesByName,
    );
  }

  CaptureValue? _extractLabelCapture(GlushList<Mark> marks, String target) {
    var cacheKey = (marks, target);
    if (parseState.labelCaptureCache.containsKey(cacheKey)) {
      GlushProfiler.incrementHit("parser.capture.cache");
      return parseState.labelCaptureCache[cacheKey];
    }
    GlushProfiler.incrementMiss("parser.capture.cache");

    // If multiple branches can produce the same capture name, we keep the
    // earliest capture as the canonical one for this forest.
    var capture = GlushProfiler.measure("parser.capture.resolve", () {
      var walker = LabelCaptureWalker(target);
      walker.walk(marks, []);
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

  ({Map<String, Object?> arguments, CallArgumentsKey key}) _resolveCallArguments(
    RuleCall call,
    Frame frame,
  ) {
    if (call.arguments.isEmpty) {
      return (arguments: const <String, Object?>{}, key: StringCallArgumentsKey(call.argumentsKey));
    }

    // Resolve arguments in the caller's environment so references can inherit
    // values, rules, or captures from the surrounding parse context.
    var callerRule = switch (frame.context.caller) {
      Caller(:var rule) => rule,
      _ => call.rule,
    };
    var callerArguments = frame.context.arguments;
    var env = _buildGuardEnvironment(rule: callerRule, frame: frame, arguments: callerArguments);
    return call.resolveArgumentsAndKey(env);
  }

  ({Map<String, Object?> arguments, CallArgumentsKey key})? _resolveParameterCallArguments(
    ParameterCallPattern pattern,
    Frame frame,
    Rule rule,
  ) {
    var callerRule = switch (frame.context.caller) {
      Caller(rule: var callerRule) => callerRule,
      _ => rule,
    };
    var callerArguments = frame.context.arguments;
    var env = _buildGuardEnvironment(rule: callerRule, frame: frame, arguments: callerArguments);
    return pattern.resolveArgumentsAndKey(env);
  }

  void _seedRuleCall({
    required Rule targetRule,
    required Pattern callPattern,
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

    var key = CallerCacheKey.create(targetRule, position, minPrecedenceLevel, callArgumentsKey);
    var caller = parseState.callers[key];
    bool isNewCaller = caller == null;
    if (isNewCaller) {
      GlushProfiler.incrementMiss("parser.callers.cache");
      caller = parseState.callers[key] = Caller(
        targetRule,
        callPattern,
        position,
        minPrecedenceLevel,
        callArgumentsKey,
        callArguments,
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
            const GlushList<Mark>.empty(),
            captures: frame.context.captures,
            predicateStack: frame.context.predicateStack,
            bsrRuleSymbol: targetRule.symbolId,
            callStart: position,
            pivot: position,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
          source: source,
          action: action,
          callSite: ParseNodeKey(currentState.id, position, frame.context.caller),
        );
      }
    } else if (isNewWaiter) {
      for (var returnContext in caller.returns) {
        _triggerReturn(
          caller,
          frame.context.caller,
          returnState,
          minPrecedenceLevel,
          frame.context,
          returnContext,
          source: ParseNodeKey(currentState.id, position, caller),
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
        const GlushList<Mark>.empty(),
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        predicateStack: nextStack,
        callStart: position,
        pivot: position,
      ),
    );
  }

  bool get accept => acceptedContexts.isNotEmpty;

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
    BranchKey? branchKey,
    ParseNodeKey? callSite,
  }) {
    GlushProfiler.increment("parser.enqueue.calls");
    var nextContext = context;
    if (isSupportingAmbiguity && source != null) {
      var nextBranchKey =
          branchKey ?? (action != null ? ActionBranchKey(action) : StateBranchKey(state));
      var nextPath = context.derivationPath.add(DerivationKey(source, nextBranchKey, callSite));
      nextContext = context.copyWith(derivationPath: nextPath);
    }

    var targetPosition = nextContext.pivot ?? 0;
    // Queue cross-position work instead of mixing pivots in this step.
    if (targetPosition != position) {
      // Cross-position work is deferred to preserve position-order semantics.
      GlushProfiler.increment("parser.enqueue.requeued");
      parseState.tracer.onEnqueue(state, targetPosition, "future position");
      requeue(Frame(nextContext)..nextStates.add(state));
      return;
    }

    // Deduplicate closure branches by merging equivalent contexts.
    var key = ContextKey.create(
      state,
      nextContext.caller,
      nextContext.minPrecedenceLevel,
      nextContext.predicateStack,
      nextContext.captures,
    );
    // Forest mode tracks alternate derivation edges for equivalent contexts.
    if (isSupportingAmbiguity) {
      // Forest mode keeps alternate derivation edges even when a context is
      // already active. Track each distinct mark branch independently so we
      // do not blend unrelated label paths together.
      var existing = _currentFrameGroups[key];
      if (existing != null) {
        // Merge marks and derivation paths if they differ.
        var nextMarks = GlushList.branched(existing.marks, nextContext.marks);
        var nextDerivation = identical(existing.derivationPath, nextContext.derivationPath)
            ? existing.derivationPath
            : GlushList.branched(existing.derivationPath, nextContext.derivationPath);

        _currentFrameGroups[key] = nextContext.copyWith(
          marks: nextMarks,
          derivationPath: nextDerivation,
        );
        GlushProfiler.increment("parser.enqueue.merged");
        return;
      }
    } else {
      // In non-forest mode, keep only the first equivalent context.
      if (!_activeContextKeys.add(key)) {
        GlushProfiler.increment("parser.enqueue.dedup_hits");
        return;
      }
    }
    GlushProfiler.increment("parser.enqueue.accepted");

    if (nextContext.predicateStack.lastOrNull case var pk?) {
      var key = PredicateKey(pk.pattern, pk.startPosition);
      parseState.predicateTrackers[key]?.addPendingFrame();
    }
    if (nextContext.caller case ConjunctionCallerKey con) {
      parseState.conjunctionTrackers[ConjunctionKey(con.left, con.right, con.startPosition)]
          ?.addPendingFrame();
    }

    _currentFrameGroups[key] = nextContext;
    _workQueue.add((key, state));
  }

  /// Execute outgoing actions for one `(frame,state)` pair.
  ///
  /// Token-consuming actions are batched into `_nextFrameGroups` and finalized
  /// together in [finalize], while zero-width actions (epsilon transitions)
  /// are enqueued immediately. This split avoids interleaving same-position
  /// closure with next-position work.
  void _process(Frame frame, State state) {
    var frameContext = frame.context;
    // Iterate over all possible actions originating from the current state.
    for (var action in state.actions) {
      parseState.tracer.onAction(action, "processing");
      // Source node for SPPF forest reconstruction.
      var source = ParseNodeKey(state.id, position, frameContext.caller);
      var callerOrRoot = frame.context.caller;
      switch (action) {
        case TokenAction():
          var token = _getTokenFor(frame);
          // Token actions fire only when an input token matches the expected pattern.
          if (token != null && action.pattern.match(token)) {
            var newMarks = frame.context.marks;
            var pattern = action.pattern;

            // Terminal capture logic: some patterns (like literal strings)
            // naturally want to be captured as marks.
            var shouldCapture =
                captureTokensAsMarks || (pattern is Token && pattern.capturesAsMark);

            // Capture policy controls whether consumed chars become human-readable StringMarks.
            if (shouldCapture) {
              newMarks = newMarks.add(StringMark(String.fromCharCode(token), position));
            }

            // Batched until finalize() so all token-consuming transitions advance
            // together to the same next-position pivot.
            var nextKey = ContextKey.create(
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
              frameContext.captures,
            );

            // Deduplicate next-position frames by merging equivalent contexts.
            var nextGroup = _nextFrameGroups[nextKey];
            nextGroup = _nextFrameGroups[nextKey] ??= ContextGroup(
              state: action.nextState,
              caller: callerOrRoot,
              minPrecedenceLevel: frameContext.minPrecedenceLevel,
              predicateStack: frameContext.predicateStack,
              captures: frameContext.captures,
            );

            // Merge the derivation path and marks into the group.
            nextGroup.marks.add(newMarks);
            if (isSupportingAmbiguity) {
              nextGroup.derivationPaths.add(frameContext.derivationPath);
            }
          }
        case BoundaryAction():
          // Boundary actions match either the start-of-input (position 0)
          // or end-of-input (token is null).
          var isMatch = action.kind == BoundaryKind.start ? position == 0 : token == null;
          if (isMatch) {
            _enqueue(
              action.nextState,
              frameContext.withMarks(frame.context.marks),
              source: source,
              action: action,
            );
          }
        case ParameterStringAction():
          var token = _getTokenFor(frame);
          if (token != null && token == action.codeUnit) {
            var newMarks = frame.context.marks;
            if (captureTokensAsMarks) {
              newMarks = newMarks.add(StringMark(String.fromCharCode(action.codeUnit), position));
            }

            var nextKey = ContextKey.create(
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
              frameContext.captures,
            );

            var nextGroup = _nextFrameGroups[nextKey];
            if (nextGroup != null) {
              GlushProfiler.incrementHit("parser.context.dedup");
            } else {
              GlushProfiler.incrementMiss("parser.context.dedup");
              nextGroup = _nextFrameGroups[nextKey] = ContextGroup(
                state: action.nextState,
                caller: callerOrRoot,
                minPrecedenceLevel: frameContext.minPrecedenceLevel,
                predicateStack: frameContext.predicateStack,
                captures: frameContext.captures,
              );
            }
            nextGroup.marks.add(newMarks);
            if (isSupportingAmbiguity) {
              nextGroup.derivationPaths.add(frameContext.derivationPath);
            }
          }
        case MarkAction():
          // Emit a named mark at the current position.
          // Used for user-defined annotations.
          var mark = NamedMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.context.marks.add(mark)),
            source: source,
            action: action,
          );
        case LabelStartAction():
          // Begin a labelled span (capture start).
          var mark = LabelStartMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.context.marks.add(mark)),
            source: source,
            action: action,
          );
        case LabelEndAction():
          // End a labelled span (capture end).
          // This allows the parser to extract the text covered by the label.
          var mark = LabelEndMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(frame.context.caller, frame.context.marks.add(mark)),
            source: source,
            action: action,
          );
        case BackreferenceAction():
          var mark = ExpandingMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(frame.context.caller, frame.context.marks.add(mark)),
            source: source,
            action: action,
          );
        case PredicateAction():
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
                nextState: action.nextState,
                isAnd: action.isAnd,
                symbol: action.symbol,
                branchKey: ActionBranchKey(action),
              );
            }
          }

          if (!tracker.exhausted) {
            // Still active; park continuation to catch future (potentially longer) matches.
            tracker.waiters.add((source, frameContext, action.nextState));

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
        case ConjunctionAction():
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
          var waiter = (source, frameContext, action.nextState);
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
        case NegationAction():
          // Negative lookahead (!pattern).
          // Continues only if the sub-parse fails to match a given span.
          var symbol = action.symbol;
          var key = NegationKey(symbol, position);
          var isFirst = !parseState.negationTrackers.containsKey(key);
          var tracker = parseState.negationTrackers[key] ??= NegationTracker(symbol, position);

          // Probing: If a pivot is already set, we check if [start, pivot] matches.
          var targetJ = frame.context.pivot;
          if (targetJ != null) {
            if (tracker.matchedPositions.contains(targetJ)) {
              // The sub-parse already matched this specific span, so negation fails.
            } else if (tracker.isExhausted) {
              // The child sub-parse is done and did NOT match targetJ; negation succeeds.
              _resumeLaggedPredicateContinuation(
                source: source,
                parentContext: frame.context,
                nextState: action.nextState,
                isAnd: true,
                symbol: action.symbol,
                branchKey: ActionBranchKey(action),
              );
            } else if (!tracker.hasWaiterAt(targetJ)) {
              // Result unknown; park until sub-parse settles for this j.
              tracker.addWaiter(targetJ, (frameContext, action.nextState));
            }
          } else {
            // Unconstrained negation: resume at EVERY position the sub-parse
            // visited where A did NOT produce a match.
            if (tracker.isExhausted) {
              // Sub-parse already done — fire for all non-matched visited positions.
              for (var j in tracker.visitedPositions) {
                if (!tracker.matchedPositions.contains(j)) {
                  requeue(Frame(frameContext.copyWith(pivot: j))..nextStates.add(action.nextState));
                }
              }
            } else {
              tracker.unconstrainedWaiters.add((frameContext, action.nextState));
            }
          }

          if (isFirst) {
            _spawnNegationSubparse(symbol, frame);
          }
        case CallAction():
          // Static rule call (GLL).
          // Resolves arguments and initiates rule expansion via GSS.
          Pattern callPattern = action.pattern;
          var call = callPattern as RuleCall;
          var resolvedCall = _resolveCallArguments(call, frame);

          _seedRuleCall(
            targetRule: action.rule,
            callPattern: callPattern,
            callArguments: resolvedCall.arguments,
            callArgumentsKey: resolvedCall.key,
            action: action,
            returnState: action.returnState,
            minPrecedenceLevel: action.minPrecedenceLevel,
            frame: frame,
            source: source,
            currentState: state,
          );
        case ParameterAction():
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
                _enqueue(
                  action.nextState,
                  frame.context.withCallerAndMarks(callerOrRoot, frame.context.marks),
                  source: source,
                  action: action,
                );
                continue;
              }
              // Redirect to a synthetic state machine that consumes the string.
              var entryState = parseState.parser.stateMachine.parameterStringEntry(
                text,
                action.nextState,
              );
              _enqueue(
                entryState,
                frame.context.withCallerAndMarks(callerOrRoot, frame.context.marks),
                source: source,
                action: action,
              );
              continue;
            case CaptureValue captureValue:
              // Data captured from a label can also be used as a parameter.
              var entryState = parseState.parser.stateMachine.parameterStringEntry(
                captureValue.value,
                action.nextState,
              );
              _enqueue(
                entryState,
                frame.context.withCallerAndMarks(callerOrRoot, frame.context.marks),
                source: source,
                action: action,
              );
            case RuleCall callValue:
              // Parameter resolves to a rule call: expansion occurs at the current position.
              var resolvedCall = _resolveCallArguments(callValue, frame);
              _seedRuleCall(
                targetRule: callValue.rule,
                callPattern: callValue,
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
                callPattern: rule,
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
              _enqueue(
                action.nextState,
                frame.context.withCallerAndMarks(callerOrRoot, frame.context.marks),
                source: source,
                action: action,
              );
            case Pattern pattern when pattern.singleToken():
              // Parameter as a single-token pattern (e.g. char ranges).
              var token = _getTokenFor(frame);
              if (token != null && pattern.match(token)) {
                _enqueue(
                  action.nextState,
                  frame.context.withCallerAndMarks(callerOrRoot, frame.context.marks),
                  source: source,
                  action: action,
                );
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
        case ParameterCallAction():
          // Rule call via a parameter reference ($paramName(args)).
          // Resolves the rule and merges call-site arguments with rule-defined ones.
          var arguments = frame.context.arguments;
          if (!arguments.containsKey(action.pattern.name)) {
            throw StateError("Missing argument '${action.pattern.name}' for parameter reference.");
          }

          var value = arguments[action.pattern.name];
          switch (value) {
            case RuleCall callValue:
              // Merge rule-provided arguments with the dynamic call-site arguments.
              var mergedArguments = <String, CallArgumentValue>{
                ...callValue.arguments,
                ...action.pattern.arguments,
              };
              var syntheticCall = RuleCall(
                callValue.name,
                callValue.rule,
                arguments: mergedArguments,
                minPrecedenceLevel:
                    callValue.minPrecedenceLevel ?? action.pattern.minPrecedenceLevel,
              );
              var resolvedCall = _resolveCallArguments(syntheticCall, frame);
              _seedRuleCall(
                targetRule: syntheticCall.rule,
                callPattern: syntheticCall,
                callArguments: resolvedCall.arguments,
                callArgumentsKey: resolvedCall.key,
                action: action,
                returnState: action.nextState,
                minPrecedenceLevel: syntheticCall.minPrecedenceLevel,
                frame: frame,
                source: source,
                currentState: state,
              );
            case Rule rule:
              // Parameter as a raw rule. We apply the call arguments to it.
              var syntheticCall = RuleCall(
                rule.name.symbol,
                rule,
                arguments: action.pattern.arguments,
                minPrecedenceLevel: action.pattern.minPrecedenceLevel,
              );
              var resolvedCall = _resolveParameterCallArguments(action.pattern, frame, rule);
              if (resolvedCall == null) {
                continue;
              }
              _seedRuleCall(
                targetRule: rule,
                callPattern: syntheticCall,
                callArguments: resolvedCall.arguments,
                callArgumentsKey: resolvedCall.key,
                action: action,
                returnState: action.nextState,
                minPrecedenceLevel: action.pattern.minPrecedenceLevel,
                frame: frame,
                source: source,
                currentState: state,
              );
            default:
              throw UnsupportedError(
                "Unsupported parameter call value for ${action.pattern.name}: ${value.runtimeType}",
              );
          }
        case ParameterPredicateAction():
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
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_eps"),
                    branchKey: ActionBranchKey(action),
                  );
                }
                continue;
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
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: predicateSymbol,
                    branchKey: ActionBranchKey(action),
                  );
                }
              } else {
                tracker.waiters.add((source, frameContext, action.nextState));
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
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: symbol,
                    branchKey: ActionBranchKey(action),
                  );
                }
              }

              if (!tracker.exhausted) {
                tracker.waiters.add((source, frameContext, action.nextState));
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
                  nextState: action.nextState,
                  isAnd: action.isAnd,
                  symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_eps"),
                  branchKey: ActionBranchKey(action),
                );
              }
            case Pattern pattern when pattern.singleToken():
              var token = _getTokenFor(frame);
              var matches = token != null && pattern.match(token);
              if (matches == action.isAnd) {
                _resumeLaggedPredicateContinuation(
                  source: source,
                  parentContext: frame.context,
                  nextState: action.nextState,
                  isAnd: action.isAnd,
                  symbol: PatternSymbol(
                    "_param_${action.isAnd ? 'and' : 'not'}_${pattern.runtimeType}",
                  ),
                  branchKey: ActionBranchKey(action),
                );
              }
            case Pattern pattern:
              throw UnsupportedError(
                "Complex parser objects used as parameter predicates are not supported yet: ${pattern.runtimeType}",
              );
          }
        case TailCallAction():
          // Tail calls still respect argument resolution and guards, but avoid
          // allocating a fresh caller when the recursion can be looped.
          var resolvedCall = _resolveCallArguments(action.pattern as RuleCall, frame);
          if (!_ruleGuardPasses(
            action.rule,
            frame,
            arguments: resolvedCall.arguments,
            argumentsKey: resolvedCall.key,
          )) {
            continue;
          }
          // Tail-call optimized recursion re-enters the rule without allocating
          // a fresh caller node. The enclosing return is unchanged, so the
          // current caller context can be reused as a simple loop back-edge.
          var firstState = parseState.parser.stateMachine.ruleFirst[action.rule.symbolId!];
          if (firstState != null) {
            _enqueue(
              firstState,
              frame.context.copyWith(
                pivot: position,
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
              continue;
            }

            bool isNewLongest = tracker.longestMatch == null || position > tracker.longestMatch!;
            if (!isNewLongest) {
              continue;
            }
            tracker.longestMatch = position;
            tracker.matched = true;

            for (var (source, parentContext, nextState) in tracker.waiters) {
              var predicateKey = parentContext.predicateStack.lastOrNull;
              if (predicateKey != null) {
                var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
                var parentTracker = parseState.predicateTrackers[key];
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
          }

          if (caller is ConjunctionCallerKey) {
            var key = ConjunctionKey(caller.left, caller.right, caller.startPosition);
            var tracker = parseState.conjunctionTrackers[key];
            if (tracker != null) {
              _finishConjunction(tracker, position, caller.isLeft, frame.context.marks);
            }
            continue;
          }

          if (caller is NegationCallerKey) {
            var key = NegationKey(caller.pattern, caller.startPosition);
            var tracker = parseState.negationTrackers[key];
            if (tracker != null) {
              tracker.markMatchedPosition(position);
            }
            continue;
          }

          // In single-derivation mode, replay each caller's returns once.
          if (!isSupportingAmbiguity && !_returnedCallers.add(caller)) {
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
              for (var (nextState, minPrecedence, parentContext, callSite) in caller.waiters) {
                _triggerReturn(
                  caller,
                  parentContext.caller,
                  nextState,
                  minPrecedence,
                  parentContext,
                  returnContext,
                  source: ParseNodeKey(state.id, position, caller),
                  action: action,
                  callSite: callSite,
                );
              }
            }
          }
        case AcceptAction():
          var accepted = frame.context;
          acceptedContexts.add(accepted);
      }
    }
  }

  /// Resume a call-site waiter with one concrete return context.
  ///
  /// This method applies call-site precedence filtering and merges marks as:
  /// `parent marks (prefix) + returned marks (call result)`.
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
      parseState.tracer.onRuleReturn(caller.rule, position, caller);
      return;
    }
    parseState.tracer.onRuleReturn(caller.rule, position, caller);
    // Fast paths for the common case where one/both mark streams are empty.
    // This avoids building branched wrappers for right-recursive call returns.
    // Continous mark streams must be concatenated, not branched.
    // Branching is for alternative derivations (same span), while rule returns
    // represent a sequence (prefix + call result).
    var nextMarks = parentContext.marks.addList(returnContext.marks);

    CaptureBindings mergedCaptures;
    if (parentContext.captures.isEmpty) {
      mergedCaptures = returnContext.captures;
    } else if (returnContext.captures.isEmpty) {
      mergedCaptures = parentContext.captures;
    } else {
      mergedCaptures = parentContext.captures.overlay(returnContext.captures);
    }

    var nextCaller = parent ?? const RootCallerKey();

    var nextContext = Context(
      nextCaller,
      nextMarks,
      arguments: parentContext.arguments,
      captures: mergedCaptures,
      derivationPath: parentContext.derivationPath.addList(returnContext.derivationPath),
      predicateStack: parentContext.predicateStack,
      bsrRuleSymbol: parentContext.bsrRuleSymbol,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
      minPrecedenceLevel: parentContext.minPrecedenceLevel,
    );

    _enqueue(nextState, nextContext, source: source, action: action, callSite: callSite);
  }

  /// Materialize batched token transitions into next-position frames.
  ///
  /// Grouping equivalent (state, caller, context) pairs here merges their
  /// derivation paths into a single branched node, preserving polynomial
  /// forest-sharing benefits while maintaining deterministic ordering.
  void finalize() {
    for (var MapEntry(:value) in _nextFrameGroups.entries) {
      var ContextGroup(
        :state,
        :caller,
        :minPrecedenceLevel,
        :predicateStack,
        :derivationPaths,
        :marks,
        :captures,
      ) = value;

      var branchedMarks = marks.fold(const GlushList<Mark>.empty(), GlushList.branched);
      var callerStartPosition = (caller is Caller)
          ? caller.startPosition
          : (caller is RootCallerKey ? 0 : null);
      var branchedDerivations = isSupportingAmbiguity
          ? derivationPaths.fold(const GlushList<DerivationKey>.empty(), GlushList.branched)
          : derivationPaths.firstOrNull ?? const GlushList<DerivationKey>.empty();

      var nextFrame = Frame(
        Context(
          caller,
          branchedMarks,
          captures: captures,
          derivationPath: branchedDerivations,
          predicateStack: predicateStack,
          bsrRuleSymbol: caller is Caller ? caller.rule.symbolId! : null,
          callStart: callerStartPosition,
          pivot: position + 1,
          minPrecedenceLevel: minPrecedenceLevel,
        ),
      );
      nextFrame.nextStates.add(state);

      if (predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        // Next frame belongs to a predicate branch and counts as pending.
        var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
        var tracker = parseState.predicateTrackers[key];

        if (tracker != null) {
          // The newly materialized next-frame is pending work for this predicate.
          tracker.addPendingFrame();
        }
      }

      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
  }

  /// Compute the same-position closure for a given frame.
  ///
  /// This method explores all epsilon transitions departing from the frame's
  /// entry state. In ambiguity mode, distinct mark branches are tracked.
  void processFrame(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      parseState.tracer.onProcessState(frame, state);
      _enqueue(state, frame.context);
    }
    while (_workQueue.isNotEmpty) {
      var (key, state) = _workQueue.removeFirst();
      var context = _currentFrameGroups.remove(key);
      if (context == null) {
        // This can happen if the queue outlived its accompanying context group
        // during complex transitions or duplicates in the work queue.
        continue;
      }
      if (!frame.replay) {
        if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
          // Contract note:
          // Being in a predicate stack does not strictly guarantee tracker
          // presence here because exhaustion cleanup can remove a tracker before
          // all delayed frames are drained.
          // This context belongs to a predicate sub-parse; update its tracker.
          var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
          var tracker = parseState.predicateTrackers[key];
          if (tracker != null) {
            // Work unit is now being processed; decrement "pending work" counter.
            tracker.removePendingFrame();
          }
        }
        if (context.caller case ConjunctionCallerKey c) {
          // Decrement pending frame counter for the conjunction sub-parse.
          var tracker =
              parseState.conjunctionTrackers[ConjunctionKey(c.left, c.right, c.startPosition)];
          if (tracker != null && tracker.activeFrames > 0) {
            tracker.removePendingFrame();
          }
        }

        if (frame.context.caller case NegationCallerKey caller) {
          parseState
              .negationTrackers[NegationKey(caller.pattern, caller.startPosition)] //
              ?.visitedPositions
              .add(position);
        }
      }
      _process(Frame(context, replay: frame.replay), state);
    }
  }

  /// Enqueue a frame without processing the work queue.
  /// Use this with processFrameFinalize() for batching.
  void processFrameEnqueue(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      parseState.tracer.onProcessState(frame, state);
      _enqueue(state, frame.context);
    }
  }

  /// Process all accumulated work from previous processFrameEnqueue() calls.
  /// This must be called after all frames at a position have been enqueued.
  void processFrameFinalize() {
    // Track if we're in replay mode - frames added during finalize phase are not replay
    while (_workQueue.isNotEmpty) {
      var (key, state) = _workQueue.removeFirst();
      var context = _currentFrameGroups.remove(key);
      if (context == null) {
        // This can happen if the queue outlived its accompanying context group
        // during complex transitions or duplicates in the work queue.
        continue;
      }

      // Handle tracker bookkeeping - these checks need to happen before processing
      if (context.predicateStack.lastOrNull case PredicateCallerKey predicateKey) {
        var key = PredicateKey(predicateKey.pattern, predicateKey.startPosition);
        var tracker = parseState.predicateTrackers[key];
        if (tracker != null) {
          tracker.removePendingFrame();
        }
      }
      if (context.caller case ConjunctionCallerKey c) {
        var key = ConjunctionKey(c.left, c.right, c.startPosition);
        var tracker = parseState.conjunctionTrackers[key];
        if (tracker != null && tracker.activeFrames > 0) {
          tracker.removePendingFrame();
        }
      }

      if (context.caller case NegationCallerKey caller) {
        parseState
            .negationTrackers[NegationKey(caller.pattern, caller.startPosition)] //
            ?.visitedPositions
            .add(position);
      }

      _process(Frame(context), state);
    }
  }
}
