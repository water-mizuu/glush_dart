/// Core parser utilities and data structures for the Glush Dart parser.
import "dart:collection";
import "dart:math" show max;

import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
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
/// (state, caller, minimumPrecedence, predicateStack, capturesKey)
/// Used for deduplication and result grouping.
/// Represents a successful parse result at a specific state and context.
typedef AcceptedContext = (State state, Context context);

/// Identifies a parser continuation point by state, position, and caller context.
typedef ParseNodeKey = (int stateId, int position, CallerKey? caller);

/// Immutable key representing a parser context identified by state, caller, precedence, and predicate stack.
@immutable
final class _ContextKey {
  _ContextKey(this.state, this.caller, this.minimumPrecedence, this.predicateStack)
    : _hash = Object.hash(_ContextKey, state, caller, minimumPrecedence, predicateStack);

  final State state;
  final CallerKey caller;
  final int? minimumPrecedence;
  final GlushList<PredicateCallerKey> predicateStack;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _ContextKey && _hash == other._hash;

  @override
  int get hashCode => _hash;
}

/// Cache key for guard evaluation results, used to memoize guard checks.
@immutable
final class _GuardCacheKey {
  _GuardCacheKey(
    this.rule,
    this.guard,
    this.marks,
    this.callArgumentsKey,
    this.position,
    this.callStart,
    this.precedenceLevel,
  ) : _hash = Object.hash(
        _GuardCacheKey,
        rule,
        guard,
        marks,
        callArgumentsKey,
        position,
        callStart,
        precedenceLevel,
      );

  final Rule rule;
  final GuardExpr guard;
  final GlushList<Mark> marks;
  final Object callArgumentsKey;
  final int position;
  final int? callStart;
  final int? precedenceLevel;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _GuardCacheKey && _hash == other._hash;

  @override
  int get hashCode => _hash;
}

/// Cache key for memoizing rule call sites based on rule, precedence, and arguments.
@immutable
final class _CallerCacheKey {
  _CallerCacheKey(this.rule, this.startPosition, this.minPrecedenceLevel, this.callArgumentsKey)
    : _hash = Object.hash(rule, startPosition, minPrecedenceLevel, callArgumentsKey);

  final Rule rule;
  final int startPosition;
  final int? minPrecedenceLevel;
  final Object callArgumentsKey;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CallerCacheKey &&
          _hash == other._hash &&
          rule == other.rule &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          callArgumentsKey == other.callArgumentsKey;

  @override
  int get hashCode => _hash;
}

/// Key for tracking waiting frames at a rule call site, to be resumed upon completion.
@immutable
final class _WaiterKey {
  _WaiterKey(this.next, this.minPrecedence, this.callerContext)
    : _hash = Object.hash(next, minPrecedence, callerContext);

  final State next;
  final int? minPrecedence;
  final Context callerContext;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _WaiterKey &&
          _hash == other._hash &&
          next == other.next &&
          minPrecedence == other.minPrecedence &&
          callerContext == other.callerContext;

  @override
  int get hashCode => _hash;
}

/// Represents a waiting frame at a rule call site, to be resumed upon completion.
typedef WaiterInfo = (
  State nextState,
  int? minPrecedence,
  Context parentContext,
  ParseNodeKey callSite,
);

/// Key for grouping return contexts by metadata, excluding marks.
@immutable
final class _ReturnKey {
  _ReturnKey(this.precedenceLevel, this.pivot, this.bsrRuleSymbol, this.callStart)
    : _hash = Object.hash(_ReturnKey, precedenceLevel, pivot, bsrRuleSymbol, callStart);

  final int? precedenceLevel;
  final int? pivot;
  final PatternSymbol? bsrRuleSymbol;
  final int? callStart;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ReturnKey &&
          _hash == other._hash &&
          precedenceLevel == other.precedenceLevel &&
          pivot == other.pivot &&
          bsrRuleSymbol == other.bsrRuleSymbol &&
          callStart == other.callStart;

  @override
  int get hashCode => _hash;
}

// ---------------------------------------------------------------------------
// Parse result types â€” sealed hierarchy replaces dynamic return values
// ---------------------------------------------------------------------------

/// Sealed result type returned by parser.parse().
sealed class ParseOutcome {}

/// Returned when parsing fails.
final class ParseError implements ParseOutcome, Exception {
  const ParseError(this.position);
  final int position;

  @override
  String toString() => "ParseError at position $position";
}

final class NegationCallerKey implements CallerKey {
  const NegationCallerKey(this.pattern, this.startPosition);
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
final class ParseSuccess implements ParseOutcome {
  const ParseSuccess(this.result);
  final ParserResult result;
}

/// Returned when parsing succeeds with an ambiguous forest.
final class ParseAmbiguousForestSuccess implements ParseOutcome {
  const ParseAmbiguousForestSuccess(this.forest);
  final GlushList<Mark> forest;
}

/// Returned when parsing succeeds with a full parse forest.
final class ParseForestSuccess implements ParseOutcome {
  const ParseForestSuccess(this.forest);
  final ParseForest forest;
  @override
  String toString() => "ParseForestSuccess(forest=$forest)";
}

extension ShowErrors on ParseError {
  void displayError(String input) {
    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    /// Surely the string we're trying to parse is not empty.
    if (inputRows.isEmpty) {
      throw StateError("Huh?");
    }

    int row = input.substring(0, position).split("\n").length;
    int column =
        input //
            .substring(0, position)
            .split("\n")
            .last
            .codeUnits
            .length +
        1;
    List<(int, String)> displayedRows = inputRows.indexed.toList().sublist(max(row - 3, 0), row);

    int longest = displayedRows.map((e) => e.$1.toString().length).reduce(max);

    print("Parse error at: ($row:$column)");
    print(
      displayedRows
          .map(
            (v) =>
                " ${(v.$1 + 1).toString().padLeft(longest)} | "
                "${v.$2}",
          )
          .join("\n"),
    );
    print("${" " * " ${''.padLeft(longest)} | ".length}${' ' * (column - 1)}^");
  }
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
  }) : frames = initialFrames,
       rulesByName = {for (var rule in parser.grammar.rules) rule.name.symbol: rule};

  /// The parser definition being executed.
  final GlushParser parser;

  /// True when multiple derivations must be preserved instead of deduped.
  final bool isSupportingAmbiguity;

  /// True when consumed exact tokens should be emitted as `StringMark`s.
  final bool captureTokensAsMarks;

  /// Optional BSR sink used by forest-oriented parser entry points.
  final BsrSet? bsr;

  /// Token history indexed by input position so lagging frames can catch up.
  final List<int> historyByPosition = [];

  /// Live predicate sub-parses keyed by `(pattern, startPosition)`.
  final Map<PredicateKey, PredicateTracker> predicateTrackers = {};

  /// Live conjunction sub-parses keyed by `(left, right, startPosition)`.
  final Map<ConjunctionKey, ConjunctionTracker> conjunctionTrackers = {};

  final Map<NegationKey, NegationTracker> negationTrackers = {};

  /// Memoized call sites keyed by rule, precedence constraints, and call arguments.
  final Map<_CallerCacheKey, Caller> _callers = {};

  /// Rules indexed by source name for guard expression evaluation.
  final Map<String, Rule> rulesByName;

  /// Shared label-capture cache keyed by persistent mark forests and capture name.
  final Map<(GlushList<Mark>, String), CaptureValue?> labelCaptureCache = {};

  /// Current zero-based input position for the next token to process.
  int position = 0;

  /// Active frames carried forward to the next `processToken` call.
  List<Frame> frames;

  /// Last step produced by the parser, used for final accept/match results.
  Step? _lastStep;

  /// Process one input code unit and advance the parser by one position.
  Step processToken(int unit) {
    var step = GlushProfiler.measure("parser.process_token", () {
      return parser.processToken(
        unit,
        position,
        frames,
        parseState: this,
        bsr: bsr,
        isSupportingAmbiguity: isSupportingAmbiguity,
        captureTokensAsMarks: captureTokensAsMarks,
      );
    });
    GlushProfiler.increment("parser.process_token.calls");
    // Advance the active frame set to the next parser position.
    frames = step.nextFrames;
    position++;
    _lastStep = step;
    return step;
  }

  /// Finalize the parse at end-of-input.
  Step finish() {
    var step = GlushProfiler.measure("parser.finish", () {
      return parser.processToken(
        null,
        position,
        frames,
        parseState: this,
        bsr: bsr,
        isSupportingAmbiguity: isSupportingAmbiguity,
        captureTokensAsMarks: captureTokensAsMarks,
      );
    });
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
  const ParserResult(this._rawMarks);
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
  final Map<int, List<(Context, State)>> waiters = {};

  /// Add a waiter for a specific end position.
  void addWaiter(int endPosition, (Context, State) waiter) {
    (waiters[endPosition] ??= []).add(waiter);
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

final class _LabelCaptureFrame {
  _LabelCaptureFrame(this.name, this.startPosition);

  final String name;
  final int startPosition;
}

final class _LabelCaptureWalker {
  _LabelCaptureWalker(this.target);

  final String target;
  CaptureValue? best;

  // This walker is a tiny explicit DFS over the persistent mark forest.
  // It keeps the capture logic reusable without the hidden state that came
  // from the earlier nested local closures.
  void walk(GlushList<Mark> node, List<_LabelCaptureFrame> active) {
    switch (node) {
      case EmptyList<Mark>():
        return;
      case Push<Mark>(:var parent, :var data):
        walk(parent, active);
        visitMark(data, active);
      case Concat<Mark>(:var left, :var right):
        walk(left, active);
        walk(right, active);
      case BranchedList<Mark>(:var alternatives):
        for (var branch in alternatives) {
          walk(branch, [...active]);
        }
    }
  }

  void visitMark(Mark mark, List<_LabelCaptureFrame> active) {
    switch (mark) {
      case LabelStartMark(:var name, :var position):
        // Only the requested label name starts a capture frame.
        if (name == target) {
          active.add(_LabelCaptureFrame(name, position));
        }
      case LabelEndMark(:var name):
        if (name == target) {
          for (var i = active.length - 1; i >= 0; i--) {
            if (active[i].name == name) {
              var frame = active.removeAt(i);
              consider(CaptureValue(frame.startPosition, mark.position, ""));
              break;
            }
          }
        }
      case ConjunctionMark(:var branches):
        // Ambiguous branches need isolated active stacks, otherwise captures
        // from one derivation would leak into another.
        for (var branch in branches) {
          walk(branch, [...active]);
        }
      default:
        break;
    }
  }

  void consider(CaptureValue? candidate) {
    if (candidate == null) {
      return;
    }
    if (best == null || candidate.startPosition < best!.startPosition) {
      best = candidate;
    }
  }
}

String _captureSignatureFromMap(Map<String, CaptureValue?> captures) {
  if (captures.isEmpty) {
    return "";
  }
  var entries = captures.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  var buffer = StringBuffer();
  for (var entry in entries) {
    buffer.write(entry.key);
    buffer.write("=");
    var value = entry.value;
    if (value == null) {
      buffer.write("null");
    } else {
      buffer
        ..write(value.startPosition)
        ..write(":")
        ..write(value.endPosition)
        ..write(":")
        ..write(value.value.length)
        ..write(":")
        ..write(value.value);
    }
    buffer.write(";");
  }
  return buffer.toString();
}

@immutable
final class CaptureBindings {
  const CaptureBindings._(this.parent, this.delta);
  const CaptureBindings.empty() : parent = null, delta = null;

  final CaptureBindings? parent;
  final Map<String, CaptureValue?>? delta;

  bool get isEmpty => (delta == null || delta!.isEmpty) && (parent == null || parent!.isEmpty);

  CaptureValue? operator [](String key) {
    if (delta case var current? when current.containsKey(key)) {
      return current[key];
    }
    return parent?[key];
  }

  bool containsKey(String key) =>
      (delta?.containsKey(key) ?? false) || (parent?.containsKey(key) ?? false);

  CaptureBindings overlay(CaptureBindings overlay) {
    if (overlay.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return overlay;
    }
    return CaptureBindings._(this, overlay.toMap());
  }

  static final Expando<Map<String, CaptureValue?>> _maps = Expando();
  Map<String, CaptureValue?> toMap() {
    var cached = _maps[this];
    if (cached != null) {
      return cached;
    }

    Map<String, CaptureValue?> computed;
    if (parent == null) {
      computed = delta == null || delta!.isEmpty
          ? const <String, CaptureValue?>{}
          : Map.unmodifiable(delta!);
    } else {
      var merged = <String, CaptureValue?>{...parent!.toMap()};
      if (delta != null && delta!.isNotEmpty) {
        merged.addAll(delta!);
      }
      computed = Map.unmodifiable(merged);
    }
    _maps[this] = computed;
    GlushProfiler.increment("parser.bindings.map_cache_assign");
    return computed;
  }

  static final Expando<String> _signatures = Expando();
  String get signature {
    var sig = _signatures[this];
    if (sig != null) {
      return sig;
    }
    sig = _captureSignatureFromMap(toMap());
    _signatures[this] = sig;
    GlushProfiler.increment("parser.bindings.signature_cache_assign");
    return sig;
  }
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
  Caller(
    this.rule,
    this.pattern,
    this.startPosition,
    this.minPrecedenceLevel,
    this.callArgumentsKey,
    Map<String, Object?> arguments,
  ) : arguments = Map<String, Object?>.unmodifiable(arguments);
  final Rule rule;
  final Pattern pattern;
  final int startPosition;
  final int? minPrecedenceLevel;
  final Object callArgumentsKey;
  final Map<String, Object?> arguments;
  final List<WaiterInfo> waiters = [];
  final Map<_ReturnKey, Context> _returns = {};
  final Set<_WaiterKey> _waiterKeys = {};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Caller &&
          runtimeType == other.runtimeType &&
          rule == other.rule &&
          pattern == other.pattern &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          callArgumentsKey == other.callArgumentsKey;

  @override
  int get hashCode =>
      Object.hash(rule, pattern, startPosition, minPrecedenceLevel, callArgumentsKey);

  bool addWaiter(State next, int? minPrecedence, Context callerContext, ParseNodeKey node) {
    var waiterKey = _WaiterKey(next, minPrecedence, callerContext);
    if (!_waiterKeys.add(waiterKey)) {
      return false;
    }
    waiters.add((next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(Context context) {
    var key = _ReturnKey(
      context.precedenceLevel,
      context.pivot,
      context.bsrRuleSymbol,
      context.callStart,
    );

    var existing = _returns[key];
    if (existing != null) {
      if (existing.marks == context.marks) {
        return false;
      }

      _returns[key] = existing.copyWith(
        marks: GlushList.branched([existing.marks, context.marks]),
        derivationPath: identical(existing.derivationPath, context.derivationPath)
            ? existing.derivationPath
            : GlushList.branched([existing.derivationPath, context.derivationPath]),
      );
      return true;
    }

    _returns[key] = context;
    return true;
  }

  Iterable<Context> get returns => _returns.values;

  Iterable<(CallerKey?, Context)> iterate() sync* {
    for (var (_, _, context, _) in waiters) {
      yield (context.caller, context);
    }
  }
}

/// Context for parsing (tracks marks, callers, and BSR call-start position).
@immutable
class Context {
  const Context(
    this.caller,
    this.marks, {
    Map<String, Object?>? arguments,
    this.captures = const CaptureBindings.empty(),
    this.derivationPath = const GlushList.empty(),
    this.predicateStack = const GlushList.empty(),
    this.bsrRuleSymbol,
    this.callStart,
    this.pivot,
    this.minPrecedenceLevel,
    this.precedenceLevel,
  }) : _arguments = arguments;
  final CallerKey caller;
  final GlushList<Mark> marks;
  final Map<String, Object?>? _arguments;
  Map<String, Object?> get arguments =>
      _arguments ??
      switch (caller) {
        Caller(:var arguments) => arguments,
        _ => const <String, Object?>{},
      };
  final CaptureBindings captures;
  final GlushList<DerivationKey> derivationPath;
  final GlushList<PredicateCallerKey> predicateStack;
  final PatternSymbol? bsrRuleSymbol;
  final int? callStart;
  final int? pivot;
  final int? minPrecedenceLevel;
  final int? precedenceLevel;

  Context copyWith({
    CallerKey? caller,
    GlushList<Mark>? marks,
    Map<String, Object?>? arguments,
    CaptureBindings? captures,
    GlushList<DerivationKey>? derivationPath,
    GlushList<PredicateCallerKey>? predicateStack,
    PatternSymbol? bsrRuleSymbol,
    int? callStart,
    int? pivot,
    int? minPrecedenceLevel,
    int? precedenceLevel,
  }) {
    var nextCaller = caller ?? this.caller;
    var nextArguments =
        arguments ?? (identical(nextCaller, this.caller) ? _arguments : this.arguments);
    return Context(
      nextCaller,
      marks ?? this.marks,
      arguments: nextArguments,
      captures: captures ?? this.captures,
      derivationPath: derivationPath ?? this.derivationPath,
      predicateStack: predicateStack ?? this.predicateStack,
      bsrRuleSymbol: bsrRuleSymbol ?? this.bsrRuleSymbol,
      callStart: callStart ?? this.callStart,
      pivot: pivot ?? this.pivot,
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
      arguments: _arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
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
      arguments: identical(nextCaller, caller) ? _arguments : arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
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
      arguments: identical(nextCaller, caller) ? _arguments : arguments,
      captures: captures,
      derivationPath: derivationPath,
      predicateStack: predicateStack,
      bsrRuleSymbol: bsrRuleSymbol,
      callStart: callStart,
      pivot: pivot,
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
          arguments == other.arguments &&
          // captures == other.captures &&
          predicateStack == other.predicateStack &&
          callStart == other.callStart &&
          pivot == other.pivot &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          precedenceLevel == other.precedenceLevel;

  @override
  int get hashCode => Object.hash(
    caller,
    marks,
    arguments,
    // captures,
    predicateStack,
    callStart,
    pivot,
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
  final Map<_ContextKey, ({List<GlushList<Mark>> marks, CaptureBindings captures})>
  _nextFrameGroups = {};
  final Map<_ContextKey, Context> _currentFrameGroups = {};
  final Set<_ContextKey> _activeContextKeys = {};
  final Queue<_ContextKey> _workQueue = DoubleLinkedQueue();
  final Set<CallerKey> _returnedCallers = {};
  final Set<AcceptedContext> _acceptedContextSet = {};
  final List<AcceptedContext> acceptedContexts = [];
  final List<Frame> requeued = [];
  final Map<_GuardCacheKey, bool> _guardResultCache = {};

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
    var conMark = ConjunctionMark([left, right], endPosition);

    for (var (source, parentContext, nextState) in targetWaiters) {
      var nextMarks = parentContext.marks.add(conMark);
      var nextContext = parentContext.copyWith(pivot: endPosition, marks: nextMarks);

      if (isSupportingAmbiguity && source != null) {
        // Record the conjunction completion in the derivation path
        var nextPath = parentContext.derivationPath.add((
          source,
          "conj", // Special marker for conjunction completion
          null,
        ));
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
    Object? branchKey,
  }) {
    var nextContext = parentContext;
    if (isSupportingAmbiguity && source != null) {
      var nextBranchKey =
          branchKey ?? PredicateAction(isAnd: isAnd, symbol: symbol, nextState: nextState);
      var nextPath = parentContext.derivationPath.add((source, nextBranchKey, null));
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
    var nextStack = frame.context.predicateStack.add(newPredicateKey);

    for (var firstState in states) {
      _enqueue(
        firstState,
        Context(
          newPredicateKey,
          const GlushList.empty(),
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          predicateStack: nextStack,
          callStart: position,
          pivot: position,
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
    parseState.conjunctionTrackers[subParseKey]; // Touch to ensure it exists if called from Action

    // Side A
    for (var s in leftStates) {
      _enqueue(
        s,
        Context(
          leftCaller,
          const GlushList.empty(),
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          pivot: position,
          predicateStack: frame.context.predicateStack,
        ),
      );
    }

    // Side B
    for (var s in rightStates) {
      _enqueue(
        s,
        Context(
          rightCaller,
          const GlushList.empty(),
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
          arguments: frame.context.arguments,
          captures: frame.context.captures,
          callStart: position,
          pivot: position,
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
    return parseState.historyByPosition[framePos];
  }

  bool _ruleGuardPasses(
    Rule rule,
    Frame frame, {
    required Map<String, Object?> arguments,
    required Object argumentsKey,
  }) {
    var guard = rule.guard;
    if (guard == null) {
      return true;
    }

    // Guard results are cached by rule, position, arguments, and mark forest so
    // repeated branches do not re-evaluate the same boolean expression.
    var subjectRule = rule.guardOwner ?? rule;
    var cacheKey = _GuardCacheKey(
      subjectRule,
      guard,
      frame.context.marks,
      argumentsKey,
      position,
      frame.context.callStart ?? position,
      frame.context.minPrecedenceLevel,
    );

    if (_guardResultCache.containsKey(cacheKey)) {
      GlushProfiler.increment("parser.guard.cache_hits");
      return _guardResultCache[cacheKey]!;
    }

    GlushProfiler.increment("parser.guard.cache_misses");
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
      valuesKey: (
        frame.context.captures.signature,
        rule.name.symbol,
        position,
        frame.context.callStart ?? position,
        frame.context.minPrecedenceLevel,
        frame.context.precedenceLevel,
      ),
      valueResolver: frame.context.captures.isEmpty ? null : (name) => frame.context.captures[name],
      captureResolver: _extractLabelCapture,
      rulesByName: parseState.rulesByName,
    );
  }

  CaptureValue? _extractLabelCapture(GlushList<Mark> marks, String target) {
    var cacheKey = (marks, target);
    if (parseState.labelCaptureCache.containsKey(cacheKey)) {
      GlushProfiler.increment("parser.capture.cache_hits");
      return parseState.labelCaptureCache[cacheKey];
    }
    GlushProfiler.increment("parser.capture.cache_misses");

    // If multiple branches can produce the same capture name, we keep the
    // earliest capture as the canonical one for this forest.
    var capture = GlushProfiler.measure("parser.capture.resolve", () {
      var walker = _LabelCaptureWalker(target);
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

  ({Map<String, Object?> arguments, Object key}) _resolveCallArguments(RuleCall call, Frame frame) {
    if (call.arguments.isEmpty) {
      return (arguments: const <String, Object?>{}, key: call.argumentsKey);
    }

    // Resolve arguments in the caller's environment so references can inherit
    // values, rules, or captures from the surrounding parse context.
    var callerRule = switch (frame.caller) {
      Caller(:var rule) => rule,
      _ => call.rule,
    };
    var callerArguments = frame.context.arguments;
    var env = _buildGuardEnvironment(rule: callerRule, frame: frame, arguments: callerArguments);
    return call.resolveArgumentsAndKey(env);
  }

  ({Map<String, Object?> arguments, Object key})? _resolveParameterCallArguments(
    ParameterCallPattern pattern,
    Frame frame,
    Rule rule,
  ) {
    var callerRule = switch (frame.caller) {
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
    required Object callArgumentsKey,
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

    var key = _CallerCacheKey(targetRule, position, minPrecedenceLevel, callArgumentsKey);
    var caller = parseState._callers[key];
    var isNewCaller = caller == null;
    GlushProfiler.increment(isNewCaller ? "parser.callers.created" : "parser.callers.reused");
    if (isNewCaller) {
      caller = parseState._callers[key] = Caller(
        targetRule,
        callPattern,
        position,
        minPrecedenceLevel,
        callArgumentsKey,
        callArguments,
      );
      GlushProfiler.increment("parser.callers.cache_assign");
    }
    var isNewWaiter = caller.addWaiter(returnState, minPrecedenceLevel, frame.context, (
      currentState.id,
      position,
      frame.context.caller,
    ));
    if (isNewCaller) {
      var states = parseState.parser.stateMachine.ruleFirst[targetRule.symbolId!] ?? [];
      for (var firstState in states) {
        _enqueue(
          firstState,
          Context(
            caller,
            const GlushList.empty(),
            captures: frame.context.captures,
            predicateStack: frame.context.predicateStack,
            bsrRuleSymbol: targetRule.symbolId,
            callStart: position,
            pivot: position,
            minPrecedenceLevel: minPrecedenceLevel,
          ),
          source: source,
          action: action,
          callSite: (currentState.id, position, frame.context.caller),
        );
      }
    } else if (isNewWaiter) {
      for (var returnContext in caller.returns) {
        _triggerReturn(
          caller,
          frame.caller,
          returnState,
          minPrecedenceLevel,
          frame.context,
          returnContext,
          source: (currentState.id, position, caller),
          action: action,
          callSite: (currentState.id, position, frame.context.caller),
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
        const GlushList.empty(),
        arguments: frame.context.arguments,
        captures: frame.context.captures,
        predicateStack: nextStack,
        callStart: position,
        pivot: position,
      ),
    );
  }

  bool get accept => acceptedContexts.isNotEmpty;

  List<Mark> get marks {
    // No accept state means no valid mark stream.
    if (acceptedContexts.isEmpty) {
      return [];
    }
    return acceptedContexts[0].$2.marks.toList();
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
    GlushProfiler.increment("parser.enqueue.calls");
    var nextContext = context;
    if (isSupportingAmbiguity && source != null) {
      var nextBranchKey = branchKey ?? action ?? state;
      var nextPath = context.derivationPath.add((source, nextBranchKey, callSite));
      nextContext = context.copyWith(derivationPath: nextPath);
    }

    var targetPosition = nextContext.pivot ?? 0;
    // Queue cross-position work instead of mixing pivots in this step.
    if (targetPosition != position) {
      // Cross-position work is deferred to preserve position-order semantics.
      GlushProfiler.increment("parser.enqueue.requeued");
      requeue(Frame(nextContext)..nextStates.add(state));
      return;
    }

    var key = _ContextKey(
      state,
      nextContext.caller,
      nextContext.minPrecedenceLevel,
      nextContext.predicateStack,
    );
    // Forest mode tracks alternate derivation edges for equivalent contexts.
    if (isSupportingAmbiguity) {
      // Forest mode keeps alternate derivation edges even when a context is
      // already active. Track each distinct mark branch independently so we
      // do not blend unrelated label paths together.
      var existing = _currentFrameGroups[key];
      if (existing != null) {
        // Merge marks and derivation paths if they differ.
        var nextMarks = GlushList.branched([existing.marks, nextContext.marks]);
        var nextDerivation = identical(existing.derivationPath, nextContext.derivationPath)
            ? existing.derivationPath
            : GlushList.branched([existing.derivationPath, nextContext.derivationPath]);

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

    var predicateKey = nextContext.predicateStack.lastOrNull;
    // Predicate-owned frames keep the tracker alive until they are processed.
    if (predicateKey != null) {
      var tracker =
          parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
      if (tracker != null) {
        tracker.addPendingFrame();
      }
    }

    if (nextContext.caller case ConjunctionCallerKey caller) {
      // Conjunction frames also keep the tracker alive.
      var tracker =
          parseState.conjunctionTrackers[(caller.left, caller.right, caller.startPosition)];
      tracker?.addPendingFrame();
    }

    _currentFrameGroups[key] = nextContext;
    _workQueue.add(key);
  }

  /// Execute outgoing actions for one `(frame,state)` pair.
  ///
  /// Token-consuming actions are batched into `_nextFrameGroups` and finalized
  /// together in [_finalize], while zero-width actions are enqueued immediately.
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
                captureTokensAsMarks || (pattern is Token && pattern.capturesAsMark);

            if (terminalSymbol != null) {
              bsr?.addTerminal(terminalSymbol, position, position + 1, token);
            }

            // Capture policy controls whether consumed chars become StringMarks.
            if (shouldCapture) {
              // Emit consumed character as mark for downstream reconstruction.
              newMarks = newMarks.add(StringMark(String.fromCharCode(token), position));
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
            var nextKey = _ContextKey(
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
            );
            var nextGroup = _nextFrameGroups[nextKey] ??= (
              marks: <GlushList<Mark>>[],
              captures: frameContext.captures,
            );
            nextGroup.marks.add(newMarks);
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
        case ParameterStringAction():
          var token = _getTokenFor(frame);
          if (token != null && token == action.codeUnit) {
            var newMarks = frame.marks;
            if (captureTokensAsMarks) {
              newMarks = newMarks.add(StringMark(String.fromCharCode(action.codeUnit), position));
            }

            if (frame.context.bsrRuleSymbol != null && frame.context.callStart != null) {
              bsr?.add(
                frame.context.bsrRuleSymbol!,
                frame.context.callStart!,
                position,
                position + 1,
              );
            }

            var nextKey = _ContextKey(
              action.nextState,
              callerOrRoot,
              frameContext.minPrecedenceLevel,
              frameContext.predicateStack,
            );

            (_nextFrameGroups[nextKey] ??= (
              marks: <GlushList<Mark>>[],
              captures: frameContext.captures,
            )).marks.add(newMarks);
          }
        case MarkAction():
          var mark = NamedMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(mark)),
            source: source,
            action: action,
          );
        case LabelStartAction():
          var mark = LabelStartMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(mark)),
            source: source,
            action: action,
          );
        case LabelEndAction():
          var mark = LabelEndMark(action.name, position);
          _enqueue(
            action.nextState,
            frameContext.withCallerAndMarks(callerOrRoot, frame.marks.add(mark)),
            source: source,
            action: action,
          );
        case PredicateAction():
          var symbol = action.symbol;
          var subParseKey = (symbol, position);
          var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);
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
          var tracker = parseState.conjunctionTrackers[key] ??= ConjunctionTracker(
            leftSymbol: left,
            rightSymbol: right,
            startPosition: position,
          );
          // Park the continuation
          var waiter = (source, frameContext, action.nextState);
          tracker.waiters.add(waiter);

          // If results are already available (even if not fully exhausted),
          // catch up the new waiter immediately with all known intersections.
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
          var symbol = action.symbol;
          var key = (symbol, position);
          var isFirst = !parseState.negationTrackers.containsKey(key);
          var tracker = parseState.negationTrackers[key] ??= NegationTracker(symbol, position);

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
              tracker.addWaiter(targetJ, (frameContext, action.nextState));
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
          var arguments = frame.context.arguments;
          if (!arguments.containsKey(action.name)) {
            throw StateError("Missing argument '${action.name}' for parameter reference.");
          }

          var value = arguments[action.name];
          switch (value) {
            case String text:
              // Strings are materialized as parser input so `body: "x"` is
              // treated like literal grammar text rather than a semantic value.
              if (text.isEmpty) {
                _enqueue(
                  action.nextState,
                  frame.context.withCallerAndMarks(callerOrRoot, frame.marks),
                  source: source,
                  action: action,
                );
                continue;
              }
              var entryState = parseState.parser.stateMachine.parameterStringEntry(
                text,
                action.nextState,
              );
              _enqueue(
                entryState,
                frame.context.withCallerAndMarks(callerOrRoot, frame.marks),
                source: source,
                action: action,
              );
              continue;
            case RuleCall callValue:
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
              _seedRuleCall(
                targetRule: rule,
                callPattern: rule,
                callArguments: const {},
                callArgumentsKey: "m0{}",
                action: action,
                returnState: action.nextState,
                minPrecedenceLevel: null,
                frame: frame,
                source: source,
                currentState: state,
              );
            case Eps():
              _enqueue(
                action.nextState,
                frame.context.withCallerAndMarks(callerOrRoot, frame.marks),
                source: source,
                action: action,
              );
            case Pattern pattern when pattern.singleToken():
              var token = _getTokenFor(frame);
              if (token != null && pattern.match(token)) {
                _enqueue(
                  action.nextState,
                  frame.context.withCallerAndMarks(callerOrRoot, frame.marks),
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
          var arguments = frame.context.arguments;
          if (!arguments.containsKey(action.pattern.name)) {
            throw StateError("Missing argument '${action.pattern.name}' for parameter reference.");
          }

          var value = arguments[action.pattern.name];
          switch (value) {
            case RuleCall callValue:
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
          var arguments = frame.context.arguments;
          if (!arguments.containsKey(action.name)) {
            throw StateError("Missing argument '${action.name}' for parameter reference.");
          }

          var value = arguments[action.name];
          switch (value) {
            case String text:
              // Parameter predicates reuse the same string materialization
              // path, but they only resume the caller when AND/NOT semantics
              // say the lookahead succeeded or failed.
              if (text.isEmpty) {
                if (action.isAnd) {
                  _resumeLaggedPredicateContinuation(
                    source: source,
                    parentContext: frame.context,
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_$text"),
                    branchKey: action,
                  );
                }
                continue;
              }
              var predicateSymbol = PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_$text");
              var subParseKey = (predicateSymbol, position);
              var isFirst = !parseState.predicateTrackers.containsKey(subParseKey);
              var tracker = parseState.predicateTrackers[subParseKey] ??= PredicateTracker(
                predicateSymbol,
                position,
                isAnd: action.isAnd,
              );
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
                    symbol: predicateSymbol,
                    branchKey: action,
                  );
                }
              } else if (!isFirst && tracker.canResolveFalse) {
                if (!tracker.isAnd) {
                  _resumeLaggedPredicateContinuation(
                    source: source,
                    parentContext: frame.context,
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: predicateSymbol,
                    branchKey: action,
                  );
                }
              } else {
                tracker.waiters.add((source, frameContext, action.nextState));
                var predicateKey = frameContext.predicateStack.lastOrNull;
                if (predicateKey != null) {
                  var parentTracker = parseState
                      .predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
                  parentTracker?.addPendingFrame();
                }
              }

              if (isFirst && !tracker.matched) {
                _spawnParameterPredicateSubparse(text: text, frame: frame, isAnd: action.isAnd);
              }
            case RuleCall callValue:
              if (callValue.arguments.isNotEmpty) {
                throw UnsupportedError(
                  "Parameterized call objects are not supported in predicates yet: ${callValue.rule.name.symbol}",
                );
              }

              var rule = callValue.rule;
              var symbol = rule.symbolId;
              if (symbol == null) {
                throw StateError("Predicate rule must have a symbol id.");
              }

              var subParseKey = (symbol, position);
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
                    branchKey: action,
                  );
                }
              } else if (!isFirst && tracker.canResolveFalse) {
                if (!tracker.isAnd) {
                  _resumeLaggedPredicateContinuation(
                    source: source,
                    parentContext: frame.context,
                    nextState: action.nextState,
                    isAnd: action.isAnd,
                    symbol: symbol,
                    branchKey: action,
                  );
                }
              } else {
                tracker.waiters.add((source, frameContext, action.nextState));
                var predicateKey = frameContext.predicateStack.lastOrNull;
                if (predicateKey != null) {
                  var parentTracker = parseState
                      .predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];
                  parentTracker?.addPendingFrame();
                }
              }

              if (isFirst && !tracker.matched) {
                _spawnPredicateSubparse(symbol, frame);
              }
            case Rule rule:
              var symbol = rule.symbolId;
              if (symbol == null) {
                throw StateError("Predicate rule must have a symbol id.");
              }
              _spawnPredicateSubparse(symbol, frame);
            case Eps():
              if (action.isAnd) {
                _resumeLaggedPredicateContinuation(
                  source: source,
                  parentContext: frame.context,
                  nextState: action.nextState,
                  isAnd: action.isAnd,
                  symbol: PatternSymbol("_param_${action.isAnd ? 'and' : 'not'}_eps"),
                  branchKey: action,
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
                  branchKey: action,
                );
              }
            case Pattern pattern:
              throw UnsupportedError(
                "Complex parser objects used as parameter predicates are not supported yet: ${pattern.runtimeType}",
              );
            default:
              throw UnsupportedError(
                "Unsupported parameter value for ${action.name}: ${value.runtimeType}",
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
          var states = parseState.parser.stateMachine.ruleFirst[action.rule.symbolId!] ?? [];
          for (var firstState in states) {
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
                  waiter.$3.caller,
                  waiter.$1,
                  waiter.$2,
                  waiter.$3,
                  returnContext,
                  source: (state.id, position, caller),
                  action: action,
                  callSite: waiter.$4,
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
      nextMarks = GlushList.branched([parentContext.marks]).addList(returnContext.marks);
    }

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
      arguments: identical(nextCaller, parentContext.caller)
          ? parentContext._arguments
          : parentContext.arguments,
      captures: mergedCaptures,
      derivationPath: parentContext.derivationPath,
      predicateStack: parentContext.predicateStack,
      bsrRuleSymbol: parentContext.bsrRuleSymbol,
      callStart: parentContext.callStart,
      pivot: returnContext.pivot,
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
    for (var MapEntry(:key, :value) in _nextFrameGroups.entries) {
      var state = key.state;
      var caller = key.caller;
      var minPrecedenceLevel = key.minimumPrecedence;
      var predicateStack = key.predicateStack;
      var branchedMarks = GlushList.branched(value.marks);
      var callerStartPosition = (caller is Caller)
          ? caller.startPosition
          : (caller is RootCallerKey ? 0 : null);
      var nextFrame = Frame(
        Context(
          caller,
          branchedMarks,
          captures: value.captures,
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
        var tracker =
            parseState.predicateTrackers[(predicateKey.pattern, predicateKey.startPosition)];

        if (tracker != null) {
          // The newly materialized next-frame is pending work for this predicate.
          tracker.addPendingFrame();
        }
      }

      nextFrames.add(nextFrame);
    }
    _nextFrameGroups.clear();
  }

  /// Compute same-position closure for a frame via `_currentWorkList`.
  ///
  /// In ambiguity mode, each distinct mark branch is processed independently.
  void processFrame(Frame frame) {
    GlushProfiler.increment("parser.frames.processed");
    for (var state in frame.nextStates) {
      _enqueue(state, frame.context);
    }
    while (_workQueue.isNotEmpty) {
      var key = _workQueue.removeFirst();
      var context = _currentFrameGroups.remove(key);
      if (context == null) {
        // This can happen if the queue outlived its accompanying context group
        // during complex transitions or duplicates in the work queue.
        continue;
      }
      var state = key.state;
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
        if (context.caller case ConjunctionCallerKey caller) {
          // Decrement pending frame counter for the conjunction sub-parse.
          var tracker =
              parseState.conjunctionTrackers[(caller.left, caller.right, caller.startPosition)];

          if (tracker != null && tracker.activeFrames > 0) {
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
    _PositionWorkQueue workQueue,
    List<Frame> frames,
  ) {
    for (var frame in frames) {
      workQueue.addFrame(frame.context.pivot ?? 0, frame);
    }
  }

  /// Detect predicates that can now be resolved as exhausted (no active frames).
  ///
  /// This method repeatedly drains newly-exhausted trackers because resolving one
  /// predicate can decrement parent predicate counters and trigger further
  /// exhaustion in the same position.
  void _checkExhaustedPredicates(
    ParseState parseState,
    _PositionWorkQueue workQueue,
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
                var parentTracker = parseState.predicateTrackers[(pk.pattern, pk.startPosition)];
                if (parentTracker != null) {
                  parentTracker.addPendingFrame();
                  changed = true;
                }
              }
              workQueue.addFrame(targetPosition, nextFrame);
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
  void _enqueueAt(_PositionWorkQueue workQueue, int position, State state, Context context) {
    var frame = Frame(context)..nextStates.add(state);
    workQueue.addFrame(position, frame);
  }

  /// Detect negations that are now fully exhausted and resume surviving waiters.
  void _checkExhaustedNegations(
    ParseState parseState,
    _PositionWorkQueue workQueue,
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
            for (var (context, nextState) in waiters) {
              _enqueueAt(workQueue, j, nextState, context);
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
    if (token != null && parseState.historyByPosition.length == currentPosition) {
      parseState.historyByPosition.add(token);
    }

    var stepsAtPosition = <int, Step>{};
    var workQueue = _PositionWorkQueue();

    _enqueueFramesForPosition(parseState, workQueue, frames);

    while (workQueue.isNotEmpty) {
      var position = workQueue.firstKeyOrNull!;
      // Work queue is sorted; once position exceeds current token, stop.
      if (position > currentPosition) {
        break;
      }

      var positionFrames = workQueue.removeFirst();

      if (stepsAtPosition[position] == null) {
        // Build one Step object per position lazily on first visit.
        var positionToken = (position == currentPosition)
            ? token
            : parseState.historyByPosition[position];

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
          if (frame.context.caller case ConjunctionCallerKey caller) {
            // Decrement pending frame counter for the conjunction sub-parse.
            var tracker =
                parseState.conjunctionTrackers[(caller.left, caller.right, caller.startPosition)];

            if (tracker != null && tracker.activeFrames > 0) {
              tracker.removePendingFrame();
            }
          }
        }
        currentStep.processFrame(frame);
      }

      currentStep._finalize();

      var nextQueuedPosition = workQueue.firstKeyOrNull;
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

final class _PositionWorkQueue {
  final SplayTreeMap<int, List<Frame>> _framesByPosition = SplayTreeMap();

  bool get isEmpty => _framesByPosition.isEmpty;
  bool get isNotEmpty => _framesByPosition.isNotEmpty;

  int? get firstKeyOrNull => _framesByPosition.firstKey();

  List<Frame> removeFirst() {
    return _framesByPosition.remove(_framesByPosition.firstKey())!;
  }

  void addFrame(int position, Frame frame) {
    (_framesByPosition[position] ??= []).add(frame);
  }
}
