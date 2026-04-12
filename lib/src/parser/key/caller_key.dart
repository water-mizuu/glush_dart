/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/helper/ref.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/key/return_key.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Strongly typed key to identify a call site in the parsing state machine.
@immutable
sealed class CallerKey {
  const CallerKey();

  int get uid;
  int get startPosition;
}

/// Represents the root call context (top-level parse, not a rule call).
final class RootCallerKey extends CallerKey {
  const RootCallerKey();

  @override
  int get uid => 0;

  @override
  int get startPosition => 0;

  @override
  int get hashCode => 0;

  @override
  bool operator ==(Object other) => other is RootCallerKey;

  @override
  String toString() => "root";
}

/// Caller key for a lookahead predicate sub-parse.
final class PredicateCallerKey extends CallerKey {
  PredicateCallerKey(this.pattern, this.startPosition, {required this.isAnd, this.name})
    : uid =
          -((pattern.hashCode.abs() << 24) |
              (startPosition & 0x7FFFFF) |
              (isAnd ? 0x800000 : 0) ^ (name?.hashCode ?? 0));

  @override
  final int startPosition;

  final PatternSymbol pattern;
  final bool isAnd;
  final String? name;

  @override
  final int uid;

  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey &&
      pattern == other.pattern &&
      startPosition == other.startPosition &&
      isAnd == other.isAnd &&
      name == other.name;

  @override
  int get hashCode => Object.hash(pattern, startPosition, isAnd, name);

  @override
  String toString() {
    var desc = name != null ? "($name:$pattern)" : "($pattern)";
    var prefix = isAnd ? "&" : "!";
    return "pred($prefix$desc @ $startPosition)";
  }
}

/// Caller key for a conjunction sub-parse branch.
final class ConjunctionCallerKey extends CallerKey {
  ConjunctionCallerKey({
    required this.left,
    required this.right,
    required this.startPosition,
    required this.isLeft,
  }) : uid = -((left.hashCode.abs() << 16) | (right.hashCode.abs() << 8) | (startPosition & 0xFF));

  @override
  final int startPosition;

  final PatternSymbol left;
  final PatternSymbol right;
  final bool isLeft;

  @override
  final int uid;

  @override
  bool operator ==(Object other) =>
      other is ConjunctionCallerKey &&
      left == other.left &&
      right == other.right &&
      startPosition == other.startPosition &&
      isLeft == other.isLeft;

  @override
  int get hashCode => Object.hash(uid, isLeft);

  @override
  String toString() => "conj(${isLeft ? 'L' : 'R'}:$left & $right @ $startPosition)";
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
// ignore: must_be_immutable
class Caller extends CallerKey {
  Caller(
    this.rule,
    this.startPosition,
    this.minPrecedenceLevel,
    this.arguments,
    this.predicateStack,
    this.uid,
  );

  final Rule rule;
  final int? minPrecedenceLevel;
  final Map<String, Object?> arguments;
  final GlushList<PredicateCallerKey> predicateStack;

  @override
  final int startPosition;

  @override
  final int uid;

  final Map<int, (Context, LazyGlushList<Mark>)> _returnsInt = {};
  final Map<int, LazyReturn<Mark>> _lazyReturns = {};

  _WaiterData? _waiterData;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Caller &&
          runtimeType == other.runtimeType &&
          rule == other.rule &&
          startPosition == other.startPosition &&
          minPrecedenceLevel == other.minPrecedenceLevel &&
          predicateStack == other.predicateStack;

  @override
  int get hashCode => Object.hash(rule, startPosition, minPrecedenceLevel, predicateStack);

  @override
  String toString() {
    var args = arguments.isEmpty ? "" : " args:$arguments";
    var prec = minPrecedenceLevel == null ? "" : " prec:$minPrecedenceLevel";
    var stack = predicateStack.isEmpty ? "" : " stack:$predicateStack";
    return "rule(${rule.name.symbol} @ $startPosition$args$prec$stack)";
  }

  bool addWaiter(
    State next,
    int? minPrecedence,
    Context callerContext,
    Ref<LazyGlushList<Mark>> callerMarks,
    ParseNodeKey node,
  ) {
    var waiter = _WaiterData(next, minPrecedence, callerContext, callerMarks, node);
    var data = _waiterData;

    if (data == null) {
      _waiterData = waiter;
      return true;
    }

    _WaiterData? prev;
    _WaiterData? head = data;
    while (head != null) {
      if (head.nextState == next &&
          head.minPrecedence == minPrecedence &&
          head.parentContext == callerContext &&
          head.parentMarks == callerMarks) {
        return false;
      }

      prev = head;
      head = head.next;
    }

    prev!.next = waiter;
    return true;
  }

  bool addReturn(Context context, LazyGlushList<Mark> marks) {
    var packedId = ReturnKey.getPackedId(
      context.precedenceLevel,
      context.position,
      context.callStart,
    );
    var existing = _returnsInt[packedId];

    if (existing == null) {
      _returnsInt[packedId] = (context, marks);
      return true;
    }

    var (existingContext, existingMarks) = existing;
    if (identical(existingMarks, marks)) {
      return false;
    }

    var merged = LazyGlushList.branched(existingMarks, marks);
    _returnsInt[packedId] = (existingContext, merged);

    return false;
  }

  LazyGlushList<Mark> getReturnMarks(int packedId) {
    return _returnsInt[packedId]?.$2 ?? const LazyGlushList.empty();
  }

  Iterable<(Context, LazyGlushList<Mark>)> get returns => _returnsInt.values;

  Iterable<WaiterInfo> get waiters {
    var data = _waiterData;
    if (data == null) {
      return const [];
    }

    List<WaiterInfo> infos = [];
    _WaiterData? head = data;
    while (head != null) {
      infos.add(WaiterInfo(head));
      head = head.next;
    }
    return infos;
  }

  /// Get or create the LazyReturn proxy for a given packedId.
  /// Ensures identical(ruleReturn(id1), ruleReturn(id1)) == true for the same id,
  /// enabling critical identity-based dedup in addReturn().
  LazyReturn<Mark> getLazyReturn(int packedId, LazyGlushList<Mark> Function() provider) {
    return _lazyReturns[packedId] ??= LazyReturn(provider);
  }
}

class _WaiterData {
  _WaiterData(
    this.nextState,
    this.minPrecedence,
    this.parentContext,
    this.parentMarks,
    this.callSite,
  );

  final State nextState;
  final int? minPrecedence;
  final Context parentContext;
  final Ref<LazyGlushList<Mark>> parentMarks;
  final ParseNodeKey callSite;

  _WaiterData? next;
}

extension type const WaiterInfo(_WaiterData _) {
  State get nextState => _.nextState;
  int? get minPrecedence => _.minPrecedence;
  Context get parentContext => _.parentContext;
  Ref<LazyGlushList<Mark>> get parentMarks => _.parentMarks;
  ParseNodeKey get callSite => _.callSite;
}
