import "package:glush/src/parser/common/context.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
@immutable
sealed class ContextKey {
  static ContextKey create(int stateId, Context context) {
    if (context.isSimple) {
      return IntContextKey._(Object.hash(context.caller.uid, stateId, context.minPrecedenceLevel));
    }

    return ComplexContextKey._(stateId, context);
  }
}

/// A bit-packed context key for simple, non-predicate paths.
final class IntContextKey implements ContextKey {
  const IntContextKey._(this.id);
  final int id;

  @override
  bool operator ==(Object other) => other is IntContextKey && id == other.id;

  @override
  int get hashCode => id;
}

/// A full context key for complex paths (predicates, captures, or BSR rules).
final class ComplexContextKey implements ContextKey {
  ComplexContextKey._(this.stateId, this.context)
    : _hash = Object.hash(ComplexContextKey, stateId, context);

  final int _hash;
  final int stateId;
  final Context context;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexContextKey && stateId == other.stateId && context == other.context;

  @override
  int get hashCode => _hash;
}
