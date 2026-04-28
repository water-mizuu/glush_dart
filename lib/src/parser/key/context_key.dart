import "package:glush/src/parser/common/context.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
@immutable
sealed class ContextKey {
  static ContextKey create(int stateId, Context context) {
    if (context.isSimple) {
      return IntContextKey(
        (context.caller.uid << 32) | (stateId << 8) | (context.minPrecedenceLevel ?? 0xFF),
      );
    }

    return ComplexContextKey(stateId, context);
  }
}

/// A bit-packed context key for simple, non-predicate paths.
final class IntContextKey implements ContextKey {
  const IntContextKey(this.id);
  final int id;

  @override
  bool operator ==(Object other) => other is IntContextKey && id == other.id;

  @override
  int get hashCode => id;
}

/// A full context key for complex paths (predicates, captures, or BSR rules).
final class ComplexContextKey implements ContextKey {
  ComplexContextKey(this.stateId, this.context)
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
