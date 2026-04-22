import "package:glush/glush.dart" show Caller;
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// The base class for all operational steps within the state machine.
///
/// A [StateAction] represents a single transition or side effect that the
/// parser performs when it enters a state. Actions are the "instructions" of
/// the state machine, defining how to consume tokens, navigate the grammar's
/// rule hierarchy, and manage metadata like labels and marks.
@immutable
sealed class StateAction {
  /// Base constructor for all state actions.
  const StateAction();
}

/// An action that consumes a single token from the input stream.
///
/// This is the primary mechanism for advancing the parser through the input.
/// The action specifies a [choice] (a pattern or literal) that the current
/// input token must match. If it matches, the parser advances its position
/// and transitions to [nextState].
final class TokenAction implements StateAction {
  /// Creates a token action that matches [choice] and transitions to [nextState].
  const TokenAction(this.choice, this.nextState);

  /// The pattern that the input token must satisfy.
  final TokenChoice choice;

  /// The state to transition to after successfully consuming a token.
  final State nextState;

  @override
  String toString() => "Token($choice)";
}

/// Kinds of input boundaries that can be checked.
enum BoundaryKind {
  /// Beginning of input.
  start,

  /// End of input.
  eof,
}

/// An action that asserts the parser is at a specific input boundary.
///
/// Boundary actions are used to implement anchors like `^` (start of input) or
/// `$` (end of input). They do not consume any tokens but will only allow the
/// parse path to continue if the condition is met.
final class BoundaryAction implements StateAction {
  /// Creates a boundary check for the specified [kind].
  const BoundaryAction(this.kind, this.nextState);

  /// Whether to check for the start of input or the end of file (EOF).
  final BoundaryKind kind;

  /// The state to transition to if the boundary condition is satisfied.
  final State nextState;

  @override
  String toString() => "Boundary(${kind.name})";
}

/// An action that begins a labeled capture group.
///
/// Labeled groups allow the parser to extract specific sub-strings or sub-trees
/// from the input. This action records the start position of the label in the
/// mark stream and pushes the label onto the active stack for forest
/// construction.
final class LabelStartAction implements StateAction {
  /// Creates a label start action for the given [name].
  const LabelStartAction(this.name, this.nextState);

  /// The name of the capture group.
  final String name;

  /// The state to transition to after starting the label.
  final State nextState;
}

/// An action that completes a labeled capture group.
///
/// This action marks the end of a group started by a [LabelStartAction]. It
/// calculates the final span of the captured input and records it in the
/// Mark stream.
final class LabelEndAction implements StateAction {
  /// Creates a label end action for the given [name].
  const LabelEndAction(this.name, this.nextState);

  /// The name of the capture group being closed.
  final String name;

  /// The state to transition to after closing the label.
  final State nextState;
}

/// An action that invokes a grammar rule.
///
/// This is the fundamental mechanism for modularity in the grammar. It manages
/// the allocation of a new GSS node (via the [Caller] mechanism) and
/// establishes a return point ([returnState]) for when the rule completes.
final class CallAction implements StateAction {
  /// Creates a rule call action.
  const CallAction(this.ruleSymbol, this.returnState, [this.minPrecedenceLevel]);

  /// The unique symbol of the rule to be invoked.
  final PatternSymbol ruleSymbol;

  /// The state to transition to once the rule successfully returns.
  final State returnState;

  /// An optional precedence constraint for precedence climbing.
  final int? minPrecedenceLevel;

  @override
  String toString() => minPrecedenceLevel != null
      ? "CallAction($ruleSymbol^$minPrecedenceLevel)"
      : "CallAction($ruleSymbol)";
}

/// An action that performs a tail-optimized recursive rule call.
///
/// Tail-call optimization (TCO) is used to avoid stack overflow and excessive
/// memory usage in right-recursive grammars. When a rule ends with a call to
/// itself (or another compatible rule), the machine uses this action to reuse
/// the current GSS frame instead of allocating a new one.
final class TailCallAction implements StateAction {
  /// Creates a tail-recursive call action.
  const TailCallAction(this.ruleSymbol, [this.minPrecedenceLevel]);

  /// The symbol of the rule to be invoked via tail-call.
  final PatternSymbol ruleSymbol;

  /// An optional precedence constraint for precedence climbing.
  final int? minPrecedenceLevel;

  @override
  String toString() => minPrecedenceLevel != null
      ? "TailCallAction($ruleSymbol^$minPrecedenceLevel)"
      : "TailCallAction($ruleSymbol)";
}

/// An action that signals the completion of a grammar rule.
///
/// When the parser reaches this action, it attempts to return to all callers
/// that are currently waiting for [ruleSymbol] to finish at the current
/// position. It also communicates the [precedenceLevel] of the completed path
/// to resolve ambiguity in precedence-sensitive rules.
final class ReturnAction implements StateAction {
  /// Creates a return action for the given [ruleSymbol].
  const ReturnAction(this.ruleSymbol, [this.precedenceLevel]);

  /// The symbol of the rule that has completed.
  final PatternSymbol ruleSymbol;

  /// The precedence level of the derivation that produced this return.
  final int? precedenceLevel;

  @override
  String toString() => precedenceLevel != null
      ? "ReturnAction($ruleSymbol, prec: $precedenceLevel)"
      : "ReturnAction($ruleSymbol)";
}

/// An action that indicates a successful completion of the entire parse.
///
/// This action is only present at the end of the grammar's start rule. If the
/// parser reaches an [AcceptAction] after consuming the expected input (usually
/// EOF), the parse is considered successful.
final class AcceptAction implements StateAction {
  /// Creates an accept action.
  const AcceptAction();
}

/// An action that initiates a lookahead assertion (&pattern or !pattern).
///
/// Lookahead predicates allow the parser to check if a pattern matches (or
/// fails to match) at the current position without advancing the input. This
/// action spawns a sub-parse that resolves the condition and notifies the
/// parent path to resume upon success (for `&`) or failure (for `!`).
final class PredicateAction implements StateAction {
  /// Creates a lookahead predicate assertion for [symbol].
  const PredicateAction({required this.isAnd, required this.symbol, required this.nextState});

  /// True for a positive lookahead (`&`), false for a negative lookahead (`!`).
  final bool isAnd;

  /// The symbol of the rule or pattern to check.
  final PatternSymbol symbol;

  /// The state to transition to if the lookahead condition is satisfied.
  final State nextState;

  @override
  String toString() =>
      isAnd //
      ? "Predicate(&$symbol)"
      : "Predicate(!$symbol)";
}

/// An action that coordinates an intersection match between two patterns (A & B).
///
/// In a conjunction, both side A and side B must match the same input span
/// starting from the current position. This action initiates both sub-parses
/// and uses a rendezvous mechanism to ensure they both reach the same end
/// position before allowing the parse to continue.
final class ConjunctionAction implements StateAction {
  /// Creates an intersection (A & B) action.
  const ConjunctionAction({
    required this.leftSymbol,
    required this.rightSymbol,
    required this.nextState,
  });

  /// The symbol of the first pattern in the intersection.
  final PatternSymbol leftSymbol;

  /// The symbol of the second pattern in the intersection.
  final PatternSymbol rightSymbol;

  /// The state to transition to if both patterns match the same input span.
  final State nextState;

  @override
  String toString() => "Conj($leftSymbol & $rightSymbol)";
}

/// An action that instructs the parser to move one position backward in the input.
///
/// This is used for complex non-linear grammar patterns where the parser
/// needs to re-examine a previous token under a different state.
final class RetreatAction implements StateAction {
  /// Creates an action that retreats the parser to the previous position.
  const RetreatAction(this.nextState);

  /// The state to transition to at the previous position.
  final State nextState;

  @override
  String toString() => "Retreat";
}
