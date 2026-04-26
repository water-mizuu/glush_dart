import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/bytecode/bytecode_frame.dart";
import "package:glush/src/parser/bytecode/bytecode_machine.dart";
import "package:glush/src/parser/bytecode/bytecode_parse_state.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_cache_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/key/context_key.dart";
import "package:glush/src/parser/key/parse_node_key.dart";
import "package:glush/src/parser/key/return_key.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

class BytecodeStep {
  BytecodeStep(
    this.machine,
    this.parseState,
    this.token,
    this.position, {
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
    this.lookahead,
  });

  final BytecodeMachine machine;
  final BytecodeParseState parseState;
  final int? token;
  final int? lookahead;
  final int position;
  final bool isSupportingAmbiguity;
  final bool captureTokensAsMarks;

  final List<BytecodeFrame> nextFrames = [];
  final List<BytecodeFrame> requeued = [];
  final Map<Context, LazyGlushList<Mark>> acceptedContexts = {};
  List<PredicateKey>? exhaustedPredicatesSink;

  final Map<int, BytecodeContextGroup> _currentFrameGroupsInt = {};
  final Map<ComplexContextKey, BytecodeContextGroup> _currentFrameGroupsComplex = {};

  final Set<int> _activeContextKeysInt = {};
  final Set<ComplexContextKey> _activeContextKeysComplex = {};

  final List<Object> _workQueue = [];
  int _workQueueHead = 0;

  bool get hasPendingWork =>
      _workQueueHead < _workQueue.length || nextFrames.isNotEmpty || requeued.isNotEmpty;

  @pragma("vm:prefer-inline")
  void processFrameEnqueue(BytecodeFrame frame) {
    var states = frame.nextStates;
    for (var i = 0; i < states.length; i++) {
      _enqueue(states[i], frame.context, frame.marks);
    }
    (states as List).clear();
  }

  @pragma("vm:prefer-inline")
  void _enqueue(int stateId, Context context, LazyGlushList<Mark> marks) {
    if (context.position != position) {
      requeue(BytecodeFrame(context, marks, [stateId]));
      return;
    }

    if (context.isSimple) {
      var packedId =
          (context.caller.uid << 32) | (stateId << 8) | (context.minPrecedenceLevel ?? 0xFF);
      if (!isSupportingAmbiguity && !_activeContextKeysInt.add(packedId)) {
        return;
      }

      var group = _currentFrameGroupsInt[packedId];
      if (group != null) {
        group.addMarks(marks);
        return;
      }

      var newGroup = BytecodeContextGroup(stateId, context)..addMarks(marks);
      _currentFrameGroupsInt[packedId] = newGroup;
      parseState.incrementTrackers(context, "enqueue");
      _workQueue.add(packedId);
      _workQueue.add(stateId);
    } else {
      var key = ComplexContextKey(State(stateId, []), context);
      if (!isSupportingAmbiguity && !_activeContextKeysComplex.add(key)) {
        return;
      }

      var group = _currentFrameGroupsComplex[key];
      if (group != null) {
        group.addMarks(marks);
        return;
      }
      parseState.incrementTrackers(context, "enqueue");
      _currentFrameGroupsComplex[key] = BytecodeContextGroup(stateId, context)..addMarks(marks);
      _workQueue.add(key);
      _workQueue.add(stateId);
    }
  }

  void processFrameFinalize() {
    var workQueue = _workQueue;
    while (_workQueueHead < workQueue.length) {
      var key = workQueue[_workQueueHead++];
      var stateId = workQueue[_workQueueHead++] as int;
      BytecodeContextGroup? group;
      if (key is int) {
        group = _currentFrameGroupsInt.remove(key);
      } else {
        group = _currentFrameGroupsComplex.remove(key as ComplexContextKey);
      }
      if (group == null) {
        continue;
      }

      var tracker = parseState.decrementTracker(group.context, "processBatch");
      if (tracker != null) {
        exhaustedPredicatesSink?.add(tracker);
      }

      _process(group.context, group.mergedMarks, stateId);
    }
    workQueue.clear();
    _workQueueHead = 0;
  }

  @pragma("vm:prefer-inline")
  void _process(Context context, LazyGlushList<Mark> marks, int stateId) {
    var bytecode = machine.bytecode;
    var offset = machine.stateOffsets[stateId];
    var actionCount = bytecode[offset++];

    for (var i = 0; i < actionCount; i++) {
      var opcode = bytecode[offset++];
      switch (BytecodeOp.values[opcode]) {
        case BytecodeOp.token:
          var choiceId = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var choice = machine.constants.getChoice(choiceId);
          var t = _getTokenForPos(context.position);
          if (t != null && choice.matches(t)) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }
        case BytecodeOp.boundary:
          var kindIndex = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var kind = BoundaryKind.values[kindIndex];
          if ((kind == BoundaryKind.start && position == 0) ||
              (kind == BoundaryKind.eof && token == null)) {
            _enqueue(nextStateId, context, marks);
          }
        case BytecodeOp.labelStart:
          var nameId = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var name = machine.constants.getString(nameId);
          _enqueue(nextStateId, context, marks.add(LabelStartVal(name, position)));
        case BytecodeOp.labelEnd:
          var nameId = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var name = machine.constants.getString(nameId);
          _enqueue(nextStateId, context, marks.add(LabelEndVal(name, position)));
        case BytecodeOp.call:
          _processCall(
            context,
            marks,
            bytecode[offset++],
            bytecode[offset++],
            bytecode[offset++],
            stateId,
          );
        case BytecodeOp.tailCall:
          _processTailCall(context, marks, bytecode[offset++], bytecode[offset++], stateId);
        case BytecodeOp.ret:
          _processReturn(context, marks, bytecode[offset++], bytecode[offset++], stateId);
        case BytecodeOp.accept:
          _processAccept(context, marks);
        case BytecodeOp.predicate:
          _processPredicate(
            context,
            marks,
            bytecode[offset++] == 1,
            bytecode[offset++],
            bytecode[offset++],
          );
        case BytecodeOp.retreat:
          _processRetreat(context, marks, bytecode[offset++]);
      }
    }
  }

  @pragma("vm:prefer-inline")
  void _processCall(
    Context context,
    LazyGlushList<Mark> marks,
    int ruleId,
    int returnStateId,
    int minPrec,
    int currentStateId,
  ) {
    var realMinPrec = minPrec == -1 ? null : minPrec;
    var frameToken = _getTokenForPos(context.position);

    var grammar = parseState.parser.grammar as Grammar;
    var stateMachine = grammar.stateMachine;

    if (!stateMachine.canRuleStartWith(ruleId, frameToken, isAtStart: context.position == 0)) {
      return;
    }

    var key = CallerCacheKey(ruleId, position, realMinPrec);
    var caller = parseState.callers[key];
    caller ??= parseState.callers[key] = Caller(
      ruleId,
      position,
      realMinPrec,
      context.predicateStack,
      parseState.callerCounter++,
    );

    var isNewWaiter = caller.addWaiter(
      State(returnStateId, []),
      realMinPrec,
      context,
      marks,
      ParseNodeKey(currentStateId, position, context.caller),
    );
    if (caller.waiters.length == 1 && isNewWaiter) {
      var firstState = stateMachine.ruleFirst[ruleId];
      if (firstState != null) {
        _enqueue(
          firstState.id,
          Context(
            caller,
            predicateStack: context.predicateStack,
            callStart: position,
            position: position,
            minPrecedenceLevel: realMinPrec,
          ),
          const LazyGlushList<Mark>.empty(),
        );
      }
    } else if (isNewWaiter) {
      for (var (returnContext, _) in caller.returns) {
        _triggerReturn(
          caller,
          context.caller,
          returnStateId,
          realMinPrec,
          context,
          marks,
          returnContext,
          currentStateId,
        );
      }
    }
  }

  void _processTailCall(
    Context context,
    LazyGlushList<Mark> marks,
    int ruleId,
    int minPrec,
    int currentStateId,
  ) {
    var grammar = parseState.parser.grammar as Grammar;
    var stateMachine = grammar.stateMachine;
    var frameToken = _getTokenForPos(context.position);
    if (!stateMachine.canRuleStartWith(ruleId, frameToken, isAtStart: context.position == 0)) {
      return;
    }

    var firstState = stateMachine.ruleFirst[ruleId];
    if (firstState != null) {
      _enqueue(
        firstState.id,
        context.copyWith(
          position: position,
          callStart: position,
          minPrecedenceLevel: minPrec == -1 ? null : minPrec,
        ),
        marks,
      );
    }
  }

  void _processReturn(
    Context context,
    LazyGlushList<Mark> marks,
    int ruleId,
    int prec,
    int currentStateId,
  ) {
    var realPrec = prec == -1 ? null : prec;
    if (context.minPrecedenceLevel != null &&
        realPrec != null &&
        realPrec < context.minPrecedenceLevel!) {
      return;
    }

    var caller = context.caller;
    if (caller is Caller) {
      var returnContext = context.copyWith(precedenceLevel: realPrec);
      if (caller.addReturn(returnContext, marks)) {
        for (var WaiterInfo(:nextState, :minPrecedence, :parentContext, :parentMarks)
            in caller.waiters) {
          _triggerReturn(
            caller,
            parentContext.caller,
            nextState.id,
            minPrecedence,
            parentContext,
            parentMarks,
            returnContext,
            currentStateId,
          );
        }
      }
    } else if (caller is PredicateCallerKey) {
      var returnPosition = context.position;
      var key = PredicateKey(caller.pattern, caller.startPosition, isAnd: caller.isAnd);
      var tracker = parseState.trackers[key] as PredicateTracker<int>?;
      if (tracker == null) {
        return;
      }

      var isNewLongest = tracker.longestMatch == null || returnPosition > tracker.longestMatch!;
      if (!isNewLongest) {
        return;
      }
      tracker.longestMatch = returnPosition;
      tracker.matched = true;
      parseState.memoizePredicateOutcome(key, isMatched: true);

      for (var (_, parentContext, nextStateId, parentMarks) in tracker.waiters) {
        var exhausted = parseState.decrementTracker(parentContext, "childMatched");
        if (exhausted != null) {
          exhaustedPredicatesSink?.add(exhausted);
        }
        if (tracker.isAnd) {
          requeue(BytecodeFrame(parentContext, parentMarks, [nextStateId]));
        }
      }

      tracker.waiters.clear();
      parseState.removeTracker(key);
    }
  }

  void _processAccept(Context context, LazyGlushList<Mark> marks) {
    acceptedContexts[context] = LazyGlushList.branched(
      acceptedContexts[context] ?? const LazyGlushList.empty(),
      marks,
    );
  }

  void _processPredicate(
    Context context,
    LazyGlushList<Mark> marks,
    bool isAnd,
    int ruleId,
    int nextStateId,
  ) {
    var predicateKey = PredicateKey(ruleId, position, isAnd: isAnd);
    if (parseState.predicateOutcomes.containsKey(predicateKey)) {
      var matched = parseState.predicateOutcomes[predicateKey]!;
      if (matched == isAnd) {
        _enqueue(nextStateId, context, marks);
      }
      return;
    }

    var grammar = parseState.parser.grammar as Grammar;
    var stateMachine = grammar.stateMachine;
    var firstState = stateMachine.ruleFirst[ruleId];
    if (firstState == null) {
      return;
    }

    var isFirst = !parseState.trackers.containsKey(predicateKey);
    var predicateCallerKey = PredicateCallerKey(ruleId, position, isAnd: isAnd);
    var tracker =
        parseState.trackers.putIfAbsent(
              predicateKey,
              () => PredicateTracker<int>(ruleId, position, isAnd: isAnd),
            )
            as PredicateTracker<int>;

    if (tracker.matched) {
      parseState.memoizePredicateOutcome(predicateKey, isMatched: true);
      if (tracker.isAnd) {
        _enqueue(nextStateId, context, marks);
      }
      return;
    }

    if (tracker.exhausted) {
      parseState.memoizePredicateOutcome(predicateKey, isMatched: false);
      if (!isAnd) {
        _enqueue(nextStateId, context, marks);
      }
      return;
    }

    tracker.waiters.add((null, context, nextStateId, marks));
    parseState.incrementTrackers(context, "childPending");

    if (isFirst) {
      _enqueue(
        firstState.id,
        Context(
          predicateCallerKey,
          predicateStack: context.predicateStack.add(predicateCallerKey),
          callStart: position,
          position: position,
        ),
        const LazyGlushList<Mark>.empty(),
      );
    }
  }

  void _processRetreat(Context context, LazyGlushList<Mark> marks, int nextStateId) {
    if (position > 0) {
      _enqueue(nextStateId, context.advancePosition(position - 1), marks);
    }
  }

  void _triggerReturn(
    Caller caller,
    CallerKey parent,
    int nextStateId,
    int? minPrec,
    Context parentContext,
    LazyGlushList<Mark> parentMarks,
    Context returnContext,
    int currentStateId,
  ) {
    if (minPrec != null &&
        returnContext.precedenceLevel != null &&
        returnContext.precedenceLevel! < minPrec) {
      return;
    }
    var packedId = ReturnKey(
      returnContext.precedenceLevel,
      returnContext.position,
      returnContext.callStart,
    );
    var returnProxy = caller.getLazyReturn(packedId, () => caller.getReturnMarks(packedId));
    _enqueue(
      nextStateId,
      Context(
        parent,
        predicateStack: parentContext.predicateStack,
        callStart: parentContext.callStart,
        position: returnContext.position,
        minPrecedenceLevel: parentContext.minPrecedenceLevel,
      ),
      parentMarks.addList(returnProxy),
    );
  }

  void finalize() {
    // Empty, functionality moved to BytecodeParser if needed.
  }

  @pragma("vm:prefer-inline")
  void _enqueueToNextPosition(int stateId, Context context, LazyGlushList<Mark> marks) {
    var nextContext = context.advancePosition(position + 1);
    if (nextContext.callStart != nextContext.caller.startPosition) {
      nextContext = nextContext.copyWith(callStart: nextContext.caller.startPosition);
    }

    // Optimization: Check if this is a simple return immediately.
    var offset = machine.stateOffsets[stateId];
    if (machine.bytecode[offset] == 1 &&
        BytecodeOp.values[machine.bytecode[offset + 1]] == BytecodeOp.ret) {
      _process(nextContext, marks, stateId);
      return;
    }

    var frame = BytecodeFrame(nextContext, marks, [stateId]);
    parseState.incrementTrackers(nextContext, "enqueueToNextPosition");
    nextFrames.add(frame);
  }

  void requeue(BytecodeFrame frame) {
    requeued.add(frame);
    parseState.incrementTrackers(frame.context, "requeue");
  }

  @pragma("vm:prefer-inline")
  int? _getTokenForPos(int framePos) {
    if (framePos == position) {
      return token;
    }
    if (framePos == position + 1) {
      return lookahead;
    }
    var history = parseState.historyByPosition;
    if (framePos < 0 || framePos >= history.length) {
      return null;
    }
    return history[framePos];
  }
}

class BytecodeContextGroup {
  BytecodeContextGroup(this.stateId, this.context);
  final int stateId;
  final Context context;
  var mergedMarks = const LazyGlushList<Mark>.empty();

  @pragma("vm:prefer-inline")
  void addMarks(LazyGlushList<Mark> marks) {
    mergedMarks = LazyGlushList.branched(mergedMarks, marks);
  }
}
