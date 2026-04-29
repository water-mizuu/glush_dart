import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/bytecode/bytecode_frame.dart";
import "package:glush/src/parser/bytecode/bytecode_machine.dart";
import "package:glush/src/parser/bytecode/bytecode_parse_state.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/trackers.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/caller_key.dart";
import "package:glush/src/parser/key/context_key.dart";
import "package:glush/src/parser/key/return_key.dart";

class BytecodeStep {
  BytecodeStep(
    this.machine,
    this.parseState,
    this.token,
    this.position, {
    required this.isSupportingAmbiguity,
    required this.captureTokensAsMarks,
  });

  final BytecodeMachine machine;
  final BytecodeParseState parseState;
  final int? token;

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

  @pragma("vm:prefer-inline")
  void processFrameEnqueue(BytecodeFrame frame) {
    _enqueue(frame.stateId, frame.context, frame.marks);
  }

  @pragma("vm:prefer-inline")
  void _enqueue(int stateId, Context context, LazyGlushList<Mark> marks) {
    if (context.position != position) {
      requeue(BytecodeFrame(context, marks, stateId));
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
      var key = ComplexContextKey(stateId, context);
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
      switch (opcode) {
        // --- Specialised token opcodes ---
        // Each variant inlines the matching condition directly, eliminating
        // the constants-table lookup and virtual TokenChoice.matches dispatch
        // that the old single `token` opcode required.

        case BytecodeOp.tokenExact:
          var value = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          // null == int is always false in Dart, so no explicit null guard needed.
          if (_getTokenForPos(context.position) == value) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenExactNot:
          var value = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t != value) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenRange:
          var start = bytecode[offset++];
          var end = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t >= start && t <= end) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenRangeNot:
          var start = bytecode[offset++];
          var end = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && (t < start || t > end)) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenAny:
          var nextStateId = bytecode[offset++];
          if (_getTokenForPos(context.position) != null) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenAnyNot:
          // not(any) is always false for non-null tokens; consume operand only.
          offset++;

        case BytecodeOp.tokenLess:
          var bound = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t <= bound) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenLessNot:
          var bound = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t > bound) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenGreater:
          var bound = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t >= bound) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        case BytecodeOp.tokenGreaterNot:
          var bound = bytecode[offset++];
          var nextStateId = bytecode[offset++];
          var t = _getTokenForPos(context.position);
          if (t != null && t < bound) {
            _enqueueToNextPosition(nextStateId, context, marks);
          }

        // --- Boundary opcodes (formerly a single `boundary` opcode with a
        //     runtime BoundaryKind.values[] lookup; now split at compile time) ---

        case BytecodeOp.boundaryStart:
          var nextStateId = bytecode[offset++];
          if (position == 0) {
            _enqueue(nextStateId, context, marks);
          }

        case BytecodeOp.boundaryEof:
          var nextStateId = bytecode[offset++];
          if (token == null) {
            _enqueue(nextStateId, context, marks);
          }

        // --- Label opcodes ---

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

        // --- Call opcodes ---
        // The admissibility check is now a direct Int32List bitset lookup
        // against data embedded in the BytecodeMachine, replacing the
        // HashMap-based canRuleStartWith() call that traversed:
        //   parser.grammar as Grammar → grammar.stateMachine →
        //   _ruleStartAdmissibilityTables[symbol] → List<bool>[token]

        case BytecodeOp.call:
          var ruleId = bytecode[offset++];
          var firstStateId = bytecode[offset++];
          var returnStateId = bytecode[offset++];
          var minPrec = bytecode[offset++];
          var admissOff = bytecode[offset++];
          if (_checkAdmissibility(
            _getTokenForPos(context.position),
            admissOff,
            context.position == 0,
          )) {
            _processCall(context, marks, ruleId, firstStateId, returnStateId, minPrec);
          }

        case BytecodeOp.tailCall:
          var firstStateId = bytecode[offset++];
          var minPrec = bytecode[offset++];
          var admissOff = bytecode[offset++];
          if (_checkAdmissibility(
            _getTokenForPos(context.position),
            admissOff,
            context.position == 0,
          )) {
            _processTailCall(context, marks, firstStateId, minPrec);
          }

        // --- Return opcodes (split to avoid null-check overhead on the common
        //     no-precedence path) ---

        case BytecodeOp.retSimple:
          _processReturn(context, marks, null);

        case BytecodeOp.retPrec:
          _processReturn(context, marks, bytecode[offset++]);

        // --- Miscellaneous ---

        case BytecodeOp.accept:
          _processAccept(context, marks);

        case BytecodeOp.predicate:
          _processPredicate(
            context,
            marks,
            bytecode[offset++] == 1,
            bytecode[offset++],
            bytecode[offset++],
            bytecode[offset++],
          );

        case BytecodeOp.retreat:
          _processRetreat(context, marks, bytecode[offset++]);
      }
    }
  }

  /// Checks the precompiled admissibility bitset embedded in [machine].
  ///
  /// Returns true if rule at [admissOff] can start with [token] at the
  /// given [isAtStart] context. For tokens outside 0–255 the check is
  /// conservatively optimistic (returns true).
  @pragma("vm:prefer-inline")
  bool _checkAdmissibility(int? token, int admissOff, bool isAtStart) {
    var admissibility = machine.admissibility;
    if (token == null) {
      // flags word: bit 0 = eofNotAtStart, bit 1 = eofAtStart
      var flags = admissibility[admissOff + 16];
      return (flags & (isAtStart ? 2 : 1)) != 0;
    }
    if (token >= 0 && token <= 255) {
      // Each half (notAtStart / atStart) is 8 × 32-bit words = 256 bits.
      // notAtStart occupies words [admissOff .. admissOff+7],
      // atStart    occupies words [admissOff+8 .. admissOff+15].
      var wordIndex = token >> 5; // which 32-bit word
      var bitIndex = token & 31; // which bit within that word
      var word = admissibility[admissOff + (isAtStart ? 8 : 0) + wordIndex];
      return (word >> bitIndex) & 1 != 0;
    }
    // Tokens > 255 are rare (non-ASCII UTF-16); be conservative.
    return true;
  }

  @pragma("vm:prefer-inline")
  void _processCall(
    Context context,
    LazyGlushList<Mark> marks,
    int ruleId,
    int firstStateId,
    int returnStateId,
    int minPrec,
  ) {
    var realMinPrec = minPrec == -1 ? null : minPrec;

    var key = (ruleId << 32) | (position << 8) | (realMinPrec ?? 0xFF);
    var caller = parseState.callers[key];
    caller ??= parseState.callers[key] = Caller(
      ruleId,
      position,
      realMinPrec,
      context.predicateStack,
      parseState.callerCounter++,
    );

    var isNewWaiter = caller.addWaiter(returnStateId, realMinPrec, context, marks);
    if (caller.waiters.length == 1 && isNewWaiter) {
      _enqueue(
        firstStateId,
        Context(
          caller,
          predicateStack: context.predicateStack,
          callStart: position,
          position: position,
          minPrecedenceLevel: realMinPrec,
        ),
        const LazyGlushList<Mark>.empty(),
      );
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
        );
      }
    }
  }

  void _processTailCall(Context context, LazyGlushList<Mark> marks, int firstStateId, int minPrec) {
    _enqueue(
      firstStateId,
      context.copyWith(
        position: position,
        callStart: position,
        minPrecedenceLevel: minPrec == -1 ? null : minPrec,
      ),
      marks,
    );
  }

  void _processReturn(
    Context context,
    LazyGlushList<Mark> marks,
    int? realPrec, // already typed as int? — no -1 sentinel needed
  ) {
    if (context.minPrecedenceLevel != null &&
        realPrec != null &&
        realPrec < context.minPrecedenceLevel!) {
      return;
    }

    var caller = context.caller;
    if (caller is Caller) {
      var returnContext = context.copyWith(precedenceLevel: realPrec);
      if (caller.addReturn(returnContext, marks)) {
        for (var WaiterInfo(:nextStateId, :minPrecedence, :parentContext, :parentMarks)
            in caller.waiters) {
          _triggerReturn(
            caller,
            parentContext.caller,
            nextStateId,
            minPrecedence,
            parentContext,
            parentMarks,
            returnContext,
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

      for (var (parentContext, nextStateId, parentMarks) in tracker.waiters) {
        var exhausted = parseState.decrementTracker(parentContext, "childMatched");
        if (exhausted != null) {
          exhaustedPredicatesSink?.add(exhausted);
        }
        if (tracker.isAnd) {
          requeue(BytecodeFrame(parentContext, parentMarks, nextStateId));
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
    int firstStateId,
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

    // Fast path: try direct token evaluation for token-only predicates
    var rule = parseState.parser.stateMachine.allRules[ruleId];
    if (rule != null) {
      var bodyPattern = rule.body();
      if (bodyPattern.isTokenOnly()) {
        _handleTokenOnlyPredicate(
          pattern: bodyPattern,
          context: context,
          marks: marks,
          isAnd: isAnd,
          nextStateId: nextStateId,
          predicateKey: predicateKey,
        );
        return;
      }
    }

    // Slow path: full sub-parse for general predicates
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

    tracker.waiters.add((context, nextStateId, marks));
    parseState.incrementTrackers(context, "childPending");

    if (isFirst) {
      var nextStack = context.predicateStack.add(predicateCallerKey);
      _enqueue(
        firstStateId,
        Context(
          predicateCallerKey,
          predicateStack: nextStack,
          callStart: position,
          position: position,
        ),
        const LazyGlushList<Mark>.empty(),
      );
    }
  }

  /// Fast-path handler for token-only predicates in bytecode.
  ///
  /// Directly evaluates the pattern against the current input token without
  /// spawning a sub-parse. Token-only predicates can be resolved immediately
  /// by checking if the current token matches the pattern.
  ///
  /// This optimization significantly reduces overhead for simple lookahead
  /// predicates like `&'a'` or `!('a'|'b')`.
  void _handleTokenOnlyPredicate({
    required Pattern pattern,
    required Context context,
    required LazyGlushList<Mark> marks,
    required bool isAnd,
    required int nextStateId,
    required PredicateKey predicateKey,
  }) {
    var frameToken = _getTokenForPos(context.position);
    var matches = pattern.match(frameToken);

    // Determine if the predicate succeeds based on AND/NOT and match result
    var predicateSucceeds = isAnd ? matches : !matches;

    // Memoize the outcome for future occurrences at this position
    parseState.memoizePredicateOutcome(predicateKey, isMatched: matches);

    if (predicateSucceeds) {
      _enqueue(nextStateId, context, marks);
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

  @pragma("vm:prefer-inline")
  void _enqueueToNextPosition(int stateId, Context context, LazyGlushList<Mark> marks) {
    var nextContext = context.advancePosition(position + 1);
    if (nextContext.callStart != nextContext.caller.startPosition) {
      nextContext = nextContext.copyWith(callStart: nextContext.caller.startPosition);
    }

    // Optimisation: if the target state is a single retSimple/retPrec, execute
    // it inline rather than allocating a BytecodeFrame and deferring to the
    // next round. This avoids a frame allocation + tracker increment for the
    // very common terminal-then-return pattern.
    var bcOffset = machine.stateOffsets[stateId];
    if (machine.bytecode[bcOffset] == 1) {
      var op = machine.bytecode[bcOffset + 1];
      if (op == BytecodeOp.retSimple || op == BytecodeOp.retPrec) {
        _process(nextContext, marks, stateId);
        return;
      }
    }

    var frame = BytecodeFrame(nextContext, marks, stateId);
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
