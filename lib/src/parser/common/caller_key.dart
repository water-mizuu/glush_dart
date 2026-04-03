/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/helper/ref.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/common/return_key.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:glush/src/parser/common/waiters.dart";
import "package:meta/meta.dart";

/// Strongly typed key to identify a call site in the parsing state machine.
@immutable
sealed class CallerKey {
  const CallerKey();

  int get uid;
  int? get startPosition;
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
}

/// Caller key for a lookahead predicate sub-parse.
final class PredicateCallerKey extends CallerKey {
  PredicateCallerKey(this.pattern, this.startPosition)
    : uid = -((pattern.hashCode.abs() << 24) | (startPosition & 0xFFFFFF));

  @override
  final int startPosition;

  final PatternSymbol pattern;

  @override
  final int uid;

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
  int get hashCode => Object.hash(left, right, startPosition, isLeft);
}

/// Graph-Shared Stack (GSS) node for memoizing rule call results.
// ignore: must_be_immutable
class Caller extends CallerKey {
  Caller(
    this.rule,
    this.pattern,
    this.startPosition,
    this.minPrecedenceLevel,
    Map<String, Object?> arguments,
    this.uid,
  ) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final Rule rule;
  final Pattern pattern;
  final int? minPrecedenceLevel;
  final Map<String, Object?> arguments;

  @override
  final int startPosition;

  @override
  final int uid;

  final Map<int, (Context, GlushList<Mark>)> _returnsInt = {};
  final Set<int> _cyclicInt = {};

  _WaiterData? _waiterData;

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
    State next,
    int? minPrecedence,
    Context callerContext,
    Ref<GlushList<Mark>> callerMarks,
    ParseNodeKey node,
  ) {
    var waiter = (next, minPrecedence, callerContext, callerMarks, node);
    var data = _waiterData;

    if (data == null) {
      _waiterData = _SingleWaiter(waiter);
      return true;
    }

    switch (data) {
      case _SingleWaiter(:var existing):
        if (existing.$1 == next &&
            existing.$2 == minPrecedence &&
            existing.$3 == callerContext &&
            existing.$4 == callerMarks) {
          return false;
        }
        _waiterData = _ManyWaiters([existing, waiter]);
        return true;
      case _ManyWaiters(:var waiters):
        for (var existing in waiters) {
          if (existing.$1 == next &&
              existing.$2 == minPrecedence &&
              existing.$3 == callerContext &&
              existing.$4 == callerMarks) {
            return false;
          }
        }
        waiters.add(waiter);
        return true;
    }
  }

  bool addReturn(Context context, GlushList<Mark> marks) {
    var packedId = ReturnKey.getPackedId(context.precedenceLevel, context.pivot, context.callStart);
    var existing = _returnsInt[packedId];

    if (existing == null) {
      _returnsInt[packedId] = (context, marks);
      return true;
    }

    var (existingContext, existingMarks) = existing;
    if (existingMarks == marks) {
      return false;
    }

    if (context.pivot == context.callStart) {
      if (!_cyclicInt.add(packedId)) {
        return false;
      }
    }

    var merged = GlushList.branched(existingMarks, marks);
    _returnsInt[packedId] = (existingContext, merged);
    return true;
  }

  Iterable<(Context, GlushList<Mark>)> get returns => _returnsInt.values;

  bool isCyclic(int? precedenceLevel, int? pivot, int? callStart) {
    return _cyclicInt.contains(ReturnKey.getPackedId(precedenceLevel, pivot, callStart));
  }

  Iterable<WaiterInfo> get waiters {
    var data = _waiterData;
    if (data == null) {
      return const [];
    }
    return switch (data) {
      _SingleWaiter(:var existing) => [existing],
      _ManyWaiters(:var waiters) => waiters,
    };
  }
}

sealed class _WaiterData {}

final class _SingleWaiter extends _WaiterData {
  _SingleWaiter(this.existing);
  final WaiterInfo existing;
}

final class _ManyWaiters extends _WaiterData {
  _ManyWaiters(this.waiters);
  final List<WaiterInfo> waiters;
}

/// Represents a negation caller key, used to track negation calls in the parse tree.
final class NegationCallerKey implements CallerKey {
  NegationCallerKey(this.pattern, this.startPosition)
    : uid = -((pattern.hashCode.abs() << 12) | (startPosition & 0xFFF));
  final PatternSymbol pattern;
  @override
  final int startPosition;

  @override
  final int uid;

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
