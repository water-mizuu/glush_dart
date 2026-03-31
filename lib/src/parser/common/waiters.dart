import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:meta/meta.dart";

/// Key for identifying unique waiters at a rule call site.
@immutable
final class WaiterKey {
  WaiterKey(this.next, this.minPrecedence, this.callerContext)
    : _hash = Object.hash(next, minPrecedence, callerContext);

  final State next;
  final int? minPrecedence;
  final Context callerContext;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WaiterKey &&
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
