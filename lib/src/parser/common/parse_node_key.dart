import "package:glush/src/parser/common/caller_key.dart";
import "package:meta/meta.dart";

/// Identifies a parser continuation point uniquely.
///
/// Combines the state ID, current position, and the Graph-Shared Stack (GSS)
/// caller to ensure that work is only shared when all contexts are identical.
@immutable
class ParseNodeKey {
  const ParseNodeKey(this.stateId, this.position, this.caller);
  final int stateId;
  final int position;
  final CallerKey? caller;

  @override
  bool operator ==(Object other) =>
      other is ParseNodeKey &&
      stateId == other.stateId &&
      position == other.position &&
      caller == other.caller;

  @override
  int get hashCode => Object.hash(stateId, position, caller);
}
