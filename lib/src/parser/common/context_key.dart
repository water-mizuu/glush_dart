import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:meta/meta.dart";

/// Represents a unique parsing configuration at a specific input position.
@immutable
sealed class ContextKey {
  static ContextKey create(State state, Context context) {
    if (context.predicateStack.isEmpty &&
        context.captures.isEmpty &&
        context.callStart == null &&
        context.arguments.isEmpty) {
      return IntContextKey(
        (context.caller.uid << 32) | (state.id << 8) | (context.minPrecedenceLevel ?? 0xFF),
      );
    }

    return ComplexContextKey(state, context);
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
  ComplexContextKey(this.state, this.context) : _hash = Object.hash(ComplexContextKey, state, context);

  final int _hash;
  final State state;
  final Context context;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexContextKey && state == other.state && context == other.context;

  @override
  int get hashCode => _hash;
}
