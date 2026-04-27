/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/key/action_key.dart";
import "package:glush/src/parser/key/parse_node_key.dart";
import "package:glush/src/parser/key/return_key.dart";
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
  PredicateCallerKey(this.pattern, this.startPosition, {required this.isAnd})
    : key = PredicateKey(pattern, startPosition, isAnd: isAnd),
      uid = -((pattern.hashCode.abs() << 24) | (startPosition & 0x7FFFFF) | (isAnd ? 0x800000 : 0)),
      hashCode = Object.hash(PredicateCallerKey, pattern, startPosition, isAnd);

  /// Pre-allocated tracking key for sub-parse status.
  final PredicateKey key;

  @override
  final int startPosition;

  final PatternSymbol pattern;
  final bool isAnd;

  @override
  final int uid;

  @override
  final int hashCode;

  @override
  bool operator ==(Object other) =>
      other is PredicateCallerKey &&
      pattern == other.pattern &&
      startPosition == other.startPosition &&
      isAnd == other.isAnd;

  @override
  String toString() {
    var prefix = isAnd ? "&" : "!";
    return "pred($prefix @ $startPosition)";
  }
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
// ignore: must_be_immutable
class Caller extends CallerKey {
  Caller(this.rule, this.startPosition, this.minPrecedenceLevel, this.predicateStack, this.uid)
    : hashCode = Object.hash(rule, startPosition, minPrecedenceLevel, predicateStack);

  final PatternSymbol rule;
  final int? minPrecedenceLevel;
  final GlushList<PredicateCallerKey> predicateStack;

  @override
  final int startPosition;

  @override
  final int uid;

  final Map<ReturnKey, (Context, LazyGlushList<Mark>)> _returnsInt = {};
  final Map<ReturnKey, LazyReturn<Mark>> _lazyReturns = {};

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
  final int hashCode;

  @override
  String toString() {
    var prec = minPrecedenceLevel == null ? "" : " prec:$minPrecedenceLevel";
    var stack = predicateStack.isEmpty ? "" : " stack:$predicateStack";
    return "rule($rule @ $startPosition$prec$stack)";
  }

  bool addWaiter(
    int nextStateId,
    int? minPrecedence,
    Context callerContext,
    LazyGlushList<Mark> callerMarks,
    ParseNodeKey node,
  ) {
    var waiter = _WaiterData(nextStateId, minPrecedence, callerContext, callerMarks, node);
    var data = _waiterData;

    if (data == null) {
      _waiterData = waiter;
      return true;
    }

    _WaiterData? prev;
    _WaiterData? head = data;
    while (head != null) {
      if (head.nextStateId == nextStateId &&
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
    var packedId = ReturnKey(context.precedenceLevel, context.position, context.callStart);
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

  LazyGlushList<Mark> getReturnMarks(ReturnKey packedId) {
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
  LazyReturn<Mark> getLazyReturn(ReturnKey packedId, LazyGlushList<Mark> Function() provider) {
    return _lazyReturns[packedId] ??= LazyReturn(provider);
  }
}

class _WaiterData {
  _WaiterData(
    this.nextStateId,
    this.minPrecedence,
    this.parentContext,
    this.parentMarks,
    this.callSite,
  );

  final int nextStateId;
  final int? minPrecedence;
  final Context parentContext;
  final LazyGlushList<Mark> parentMarks;
  final ParseNodeKey callSite;

  _WaiterData? next;
}

extension type const WaiterInfo(_WaiterData _) {
  int get nextStateId => _.nextStateId;
  int? get minPrecedence => _.minPrecedence;
  Context get parentContext => _.parentContext;
  LazyGlushList<Mark> get parentMarks => _.parentMarks;
  ParseNodeKey get callSite => _.callSite;
}
