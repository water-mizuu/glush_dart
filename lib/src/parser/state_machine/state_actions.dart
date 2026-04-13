import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";
import "package:meta/meta.dart";

/// Base class for all actions that can occur in a state.
///
/// Actions represent transitions and side effects in the state machine,
/// such as token consumption, function calls, returns, and predicates.
@immutable
sealed class StateAction {
  const StateAction();
}

/// Action to set a mark for later backreference.
final class MarkAction implements StateAction {
  /// Create a mark action.
  ///
  /// Parameters:
  ///   [name] - The name of the mark
  ///   [nextState] - The state to transition to after marking
  const MarkAction(this.name, this.nextState);

  /// The name of this mark.
  final String name;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "Mark($name)";
}

/// Action to consume a token and transition to the next state.
final class TokenAction implements StateAction {
  /// Create a token action.
  ///
  /// Parameters:
  ///   [choice] - The token choice to consume
  ///   [nextState] - The state to transition to after consuming the token
  const TokenAction(this.choice, this.nextState);

  /// The token choice to consume.
  final TokenChoice choice;

  /// The next state after this transition.
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

/// Action to check for start or end of input boundary.
final class BoundaryAction implements StateAction {
  /// Create a boundary action.
  ///
  /// Parameters:
  ///   [kind] - The type of boundary (start or eof)
  ///   [nextState] - The state to transition to if boundary matches
  const BoundaryAction(this.kind, this.nextState);

  /// The type of boundary being checked.
  final BoundaryKind kind;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "Boundary(${kind.name})";
}

/// Action to mark the start of a labeled capture group.
final class LabelStartAction implements StateAction {
  /// Create a label start action.
  ///
  /// Parameters:
  ///   [name] - The name of the label
  ///   [nextState] - The state to transition to
  const LabelStartAction(this.name, this.nextState);

  /// The name of the label.
  final String name;

  /// The next state after this transition.
  final State nextState;
}

/// Action to mark the end of a labeled capture group.
final class LabelEndAction implements StateAction {
  /// Create a label end action.
  ///
  /// Parameters:
  ///   [name] - The name of the label
  ///   [nextState] - The state to transition to
  const LabelEndAction(this.name, this.nextState);

  /// The name of the label.
  final String name;

  /// The next state after this transition.
  final State nextState;
}

/// Action to match a previously captured label group by name.
final class BackreferenceAction implements StateAction {
  /// Create a backreference action.
  ///
  /// Parameters:
  ///   [name] - The name of the label to reference
  ///   [nextState] - The state to transition to if match succeeds
  const BackreferenceAction(this.name, this.nextState);

  /// The name of the label being referenced.
  final String name;

  /// The next state after this transition.
  final State nextState;
}

/// Action to consume a parameter value during parsing.
final class ParameterAction implements StateAction {
  /// Create a parameter action.
  ///
  /// Parameters:
  ///   [name] - The name of the parameter
  ///   [nextState] - The state to transition to
  const ParameterAction(this.name, this.nextState);

  /// The name of the parameter.
  final String name;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "Parameter($name)";
}

/// Action to call a parameterized rule.
final class ParameterCallAction implements StateAction {
  /// Create a parameter call action.
  ///
  /// Parameters:
  ///   [targetParameter] - The name of the parameter invoking the rule
  ///   [arguments] - Dynamically bound parameter scope elements
  ///   [nextState] - The state to transition to after the call returns
  ///   [minPrecedenceLevel] - Minimum precedence filter for the call
  const ParameterCallAction(
    this.targetParameter,
    this.arguments,
    this.nextState,
    this.minPrecedenceLevel,
  );

  /// The parameter executing the call.
  final String targetParameter;

  /// The arguments passed scoped locally to the parameterized call.
  final Map<String, CallArgumentValue> arguments;

  /// The next state after this transition.
  final State nextState;

  /// Minimum precedence filter for the call expansion.
  final int? minPrecedenceLevel;

  @override
  String toString() => "ParameterCall($targetParameter)";
}

/// Action to consume one character from a parameter string.
final class ParameterStringAction implements StateAction {
  /// Create a parameter string action.
  ///
  /// Parameters:
  ///   [codeUnit] - The character code to consume
  ///   [nextState] - The state to transition to after consuming
  const ParameterStringAction(this.codeUnit, this.nextState);

  /// The Unicode code unit to match.
  final int codeUnit;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "ParameterString(${String.fromCharCode(codeUnit)})";
}

/// Action to check a predicate on a parameter value.
final class ParameterPredicateAction implements StateAction {
  /// Create a parameter predicate action.
  ///
  /// Parameters:
  ///   [isAnd] - true for AND (&parameter), false for NOT (!parameter)
  ///   [name] - The parameter name to check
  ///   [nextState] - The state to transition to if predicate succeeds
  const ParameterPredicateAction({
    required this.isAnd,
    required this.name,
    required this.nextState,
  });

  /// Whether this is an AND (&) or NOT (!) predicate.
  final bool isAnd;

  /// The name of the parameter being checked.
  final String name;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => isAnd ? "ParameterPredicate(&$name)" : "ParameterPredicate(!$name)";
}

/// Action to call a rule and push a return state onto the call stack.
final class CallAction implements StateAction {
  /// Create a call action.
  ///
  /// Parameters:
  ///   [ruleSymbol] - The symbol of the rule to call
  ///   [arguments] - Explicit mapping of parameter expressions
  ///   [returnState] - The state to return to when the rule completes
  ///   [minPrecedenceLevel] - Optional minimum precedence level constraint
  const CallAction(this.ruleSymbol, this.arguments, this.returnState, [this.minPrecedenceLevel]);

  /// The rule symbol being called.
  final PatternSymbol ruleSymbol;

  /// Dynamically scoped parameterized arguments matching.
  final Map<String, CallArgumentValue> arguments;

  /// The state to return to after the call completes.
  final State returnState;

  /// Optional minimum precedence level for the call.
  final int? minPrecedenceLevel;

  @override
  String toString() => minPrecedenceLevel != null
      ? "CallAction($ruleSymbol^$minPrecedenceLevel)"
      : "CallAction($ruleSymbol)";
}

/// Action for tail-call optimization of recursive rules.
///
/// When a recursive rule can be optimized into a loop, this action is used
/// instead of CallAction to avoid stack growth.
final class TailCallAction implements StateAction {
  /// Create a tail call action.
  ///
  /// Parameters:
  ///   [ruleSymbol] - The rule symbol to tail-call
  ///   [arguments] - Explicit mapping of parameter expressions
  ///   [minPrecedenceLevel] - Optional minimum precedence level constraint
  const TailCallAction(this.ruleSymbol, this.arguments, [this.minPrecedenceLevel]);

  /// The rule being tail-called.
  final PatternSymbol ruleSymbol;

  /// Dynamically scoped parameterized arguments matching.
  final Map<String, CallArgumentValue> arguments;

  /// Optional minimum precedence level for the call.
  final int? minPrecedenceLevel;

  @override
  String toString() => minPrecedenceLevel != null
      ? "TailCallAction($ruleSymbol^$minPrecedenceLevel)"
      : "TailCallAction($ruleSymbol)";
}

/// Action to return from a rule call and pop the call stack.
final class ReturnAction implements StateAction {
  /// Create a return action.
  ///
  /// Parameters:
  ///   [ruleSymbol] - The rule being returned from
  ///   [precedenceLevel] - Optional precedence level for the return
  const ReturnAction(this.ruleSymbol, [this.precedenceLevel]);

  /// The rule this return belongs to.
  final PatternSymbol ruleSymbol;

  /// Optional precedence level associated with the return.
  final int? precedenceLevel;

  @override
  String toString() => precedenceLevel != null
      ? "ReturnAction($ruleSymbol, prec: $precedenceLevel)"
      : "ReturnAction($ruleSymbol)";
}

/// Action to accept the input and complete parsing successfully.
final class AcceptAction implements StateAction {
  /// Create an accept action.
  const AcceptAction();
}

/// Predicate action for lookahead assertions (AND/NOT predicates)
/// Does not consume input - purely a condition check
final class PredicateAction implements StateAction {
  const PredicateAction({required this.isAnd, required this.symbol, required this.nextState});

  // Marker type: true for AND (&), false for NOT (!)
  final bool isAnd;

  // The symbol for the pattern (used by shell grammars)
  final PatternSymbol symbol;

  // Next state after successful predicate check
  final State nextState;

  @override
  String toString() =>
      isAnd //
      ? "Predicate(&$symbol)"
      : "Predicate(!$symbol)";
}

/// Action for consuming intersection (A & B) of two patterns.
final class ConjunctionAction implements StateAction {
  /// Create a conjunction action.
  ///
  /// Parameters:
  ///   [leftSymbol] - The left pattern symbol
  ///   [rightSymbol] - The right pattern symbol
  ///   [nextState] - The state to transition to if both patterns match
  const ConjunctionAction({
    required this.leftSymbol,
    required this.rightSymbol,
    required this.nextState,
  });

  /// The left operand symbol.
  final PatternSymbol leftSymbol;

  /// The right operand symbol.
  final PatternSymbol rightSymbol;

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "Conj($leftSymbol & $rightSymbol)";
}

/// Action to retreat/go-back one position in the input.
final class RetreatAction implements StateAction {
  /// Create a retreat action.
  ///
  /// Parameters:
  ///   [nextState] - The state to transition to after retreating
  const RetreatAction(this.nextState);

  /// The next state after this transition.
  final State nextState;

  @override
  String toString() => "Retreat";
}
