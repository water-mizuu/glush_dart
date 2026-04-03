/// Core parser utilities and data structures for the Glush Dart parser.
import "package:glush/src/core/list.dart";
import "package:glush/src/core/patterns.dart";
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
final class Caller extends CallerKey {
  Caller(
    this.rule,
    this.pattern,
    this.startPosition,
    this.minPrecedenceLevel,
    this.callArgumentsKey,
    Map<String, Object?> arguments,
    this.uid,
  ) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final Rule rule;
  final Pattern pattern;
  final int? minPrecedenceLevel;
  final CallArgumentsKey callArgumentsKey;
  final Map<String, Object?> arguments;

  @override
  final int startPosition;

  @override
  final int uid;

  final Set<WaiterInfo> waiters = {};
  final Map<ReturnKey, Context> _returns = {};
  final Set<WaiterKey> _waiterKeys = {};
  final Set<ReturnKey> _cyclicEpsilonTriggered = {};

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
    var waiterKey = WaiterKey(next, minPrecedence, callerContext);
    if (!_waiterKeys.add(waiterKey)) {
      return false;
    }
    waiters.add((next, minPrecedence, callerContext, node));
    return true;
  }

  bool addReturn(Context context) {
    var key = ReturnKey(context.precedenceLevel, context.pivot, context.callStart);

    var existing = _returns[key];
    if (existing != null) {
      if (existing.marks == context.marks) {
        return false;
      }

      // For cyclic epsilon returns (pivot == callStart), allow only the first
      // return to trigger waiters, blocking subsequent ones to prevent infinite
      // loops in self-referential epsilon productions like: S = $mark S | '';
      if (context.pivot == context.callStart) {
        if (!_cyclicEpsilonTriggered.add(key)) {
          // Already triggered once, block subsequent attempts
          return false;
        }
        // First occurrence: allow waiter triggering
      }

      _returns[key] = existing.copyWith(marks: GlushList.branched(existing.marks, context.marks));
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
