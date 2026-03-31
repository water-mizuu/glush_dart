import "package:glush/src/core/list.dart" show GlushList;
import "package:glush/src/parser/common/caller_key.dart" show CallerKey, PredicateCallerKey;
import "package:glush/src/parser/common/label_capture.dart";
import "package:glush/src/parser/common/state_machine.dart";
import "package:meta/meta.dart";

/// Immutable key for a parsing context.
///
/// This is used to deduplicate work by identifying whether two parser paths
/// have reached reach a point with identical state, caller, and constraints.
@immutable
sealed class ContextKey {
  static ContextKey create(
    State state,
    CallerKey caller,
    int? minimumPrecedence,
    GlushList<PredicateCallerKey> predicateStack,
    CaptureBindings captures,
  ) {
    if (predicateStack.isEmpty && captures.isEmpty) {
      // Bit-pack: CallerUID (31) | StateID (24) | MinPrec (8)
      // Use 32-bit shift for caller to avoid overlap with 24-bit state ID.
      return IntContextKey((caller.uid << 32) | (state.id << 8) | (minimumPrecedence ?? 0xFF));
    }
    return ComplexContextKey(state, caller, minimumPrecedence, predicateStack, captures);
  }
}

/// A compact integer-based context key for the "fast path" (no predicates or captures).
final class IntContextKey implements ContextKey {
  IntContextKey(this.value) : _hash = Object.hash(IntContextKey, value);

  final int value;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is IntContextKey && value == other.value;

  @override
  int get hashCode => _hash;
}

/// An expensive context key for the "slow path" involving complex constraints.
@immutable
final class ComplexContextKey implements ContextKey {
  ComplexContextKey(
    this.state,
    this.caller,
    this.minimumPrecedence,
    this.predicateStack,
    this.captures,
  ) : _hash = Object.hash(
        ComplexContextKey,
        state,
        caller,
        minimumPrecedence,
        predicateStack,
        captures,
      );

  final State state;
  final CallerKey caller;
  final int? minimumPrecedence;
  final GlushList<PredicateCallerKey> predicateStack;
  final CaptureBindings captures;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComplexContextKey &&
          state == other.state &&
          caller == other.caller &&
          minimumPrecedence == other.minimumPrecedence &&
          predicateStack == other.predicateStack &&
          captures == other.captures;

  @override
  int get hashCode => _hash;
}
