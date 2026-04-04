/// Core parser utilities and data structures for the Glush Dart parser.

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_actions.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Base class for keys used to identify specific transition branches in the derivation path.
/// Used for distinguishing between different ways a parser state could advance.
@immutable
sealed class BranchKey {
  const BranchKey();
}

/// Represents a branch taken via a specific [StateAction].
final class ActionBranchKey extends BranchKey {
  const ActionBranchKey(this.action);
  final StateAction action;

  @override
  bool operator ==(Object other) => other is ActionBranchKey && other.action == action;

  @override
  int get hashCode => action.hashCode;

  @override
  String toString() => action.toString();
}

/// Represents a branch taken into a specific [State] (usually direct transitions).
final class StateBranchKey extends BranchKey {
  const StateBranchKey(this.state);
  final State state;

  @override
  bool operator ==(Object other) => other is StateBranchKey && other.state == state;

  @override
  int get hashCode => state.hashCode;

  @override
  String toString() => state.toString();
}

/// Represents a branch taken due to a lookahead predicate assertion.
final class PredicateBranchKey extends BranchKey {
  const PredicateBranchKey({required this.isAnd, required this.symbol, required this.nextState});
  final bool isAnd;
  final PatternSymbol symbol;
  final State nextState;

  @override
  bool operator ==(Object other) =>
      other is PredicateBranchKey &&
      other.isAnd == isAnd &&
      other.symbol == symbol &&
      other.nextState == nextState;

  @override
  int get hashCode => Object.hash(isAnd, symbol, nextState);
}

/// Special branch marker for rule conjunctions (&).
final class ConjunctionBranchKey extends BranchKey {
  const ConjunctionBranchKey();

  @override
  bool operator ==(Object other) => other is ConjunctionBranchKey;

  @override
  int get hashCode => (ConjunctionBranchKey).hashCode;

  @override
  String toString() => "conj";
}

/// Generic string-based branch identifier, used for custom extensions or tags.
final class StringBranchKey extends BranchKey {
  const StringBranchKey(this.key);
  final String key;

  @override
  bool operator ==(Object other) => other is StringBranchKey && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}
