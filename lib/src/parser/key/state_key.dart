import "dart:core" hide Pattern;

import "package:glush/src/core/patterns.dart";
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
