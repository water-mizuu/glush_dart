import "dart:core" hide Pattern;

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Key for identifying states in the state machine.
///
/// Used to distinguish different types of states in the state machine.
/// Each state type has its own key class for pattern matching.
@immutable
sealed class StateKey {
  const StateKey();
}

/// Key for the initial/start state of the state machine.
final class InitStateKey extends StateKey {
  const InitStateKey();

  /// Check equality with another object.
  @override
  bool operator ==(Object other) => other is InitStateKey;

  /// Get hash code for use in collections.
  @override
  int get hashCode => (InitStateKey).hashCode;

  /// Human-readable string representation.
  @override
  String toString() => ":init";
}

/// Key for states corresponding to grammar patterns.
///
/// Maps a [Pattern] (token, rule reference, etc.) to its state.
final class PatternStateKey extends StateKey {
  const PatternStateKey(this.pattern);

  /// The grammar pattern this state represents.
  final Pattern pattern;

  /// Check equality based on the pattern.
  @override
  bool operator ==(Object other) => other is PatternStateKey && other.pattern == pattern;

  /// Get hash code based on the pattern.
  @override
  int get hashCode => pattern.hashCode;

  /// Use pattern's string representation.
  @override
  String toString() => pattern.toString();
}

/// Key for states in parameter string matching chains.
///
/// Used to build chains of states that consume parameter string characters one by one.
final class ParamStringStateKey extends StateKey {
  const ParamStringStateKey(this.text, this.index, this.nextState);

  /// The parameter string being matched.
  final String text;

  /// Current position in the string.
  final int index;

  /// The state to transition to after matching this character.
  final State nextState;

  /// Check equality based on text, index, and next state.
  @override
  bool operator ==(Object other) =>
      other is ParamStringStateKey &&
      other.text == text &&
      other.index == index &&
      other.nextState == nextState;

  /// Hash based on all three components.
  @override
  int get hashCode => Object.hash(text, index, nextState);
}

/// Key for states in parameter predicate matching chains.
///
/// Used to build chains that check parameter predicates character by character.
final class ParamPredicateStateKey extends StateKey {
  const ParamPredicateStateKey(this.text, this.index);

  /// The parameter text being checked.
  final String text;

  /// Current position in the text.
  final int index;

  /// Check equality based on text and index.
  @override
  bool operator ==(Object other) =>
      other is ParamPredicateStateKey && other.text == text && other.index == index;

  /// Hash based on text and index.
  @override
  int get hashCode => Object.hash(text, index);
}

/// Key for the terminal state of a parameter predicate chain.
///
/// Represents the end of a predicate matching sequence.
final class ParamPredicateEndStateKey extends StateKey {
  const ParamPredicateEndStateKey(this.text);

  /// The parameter text that was fully matched.
  final String text;

  /// Check equality based on text.
  @override
  bool operator ==(Object other) => other is ParamPredicateEndStateKey && other.text == text;

  /// Hash based on text.
  @override
  int get hashCode => text.hashCode;
}
