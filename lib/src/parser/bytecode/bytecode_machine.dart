import "dart:typed_data";

import "package:glush/src/parser/bytecode/constants_table.dart";

/// Opcode definitions for the bytecode state machine.
enum BytecodeOp {
  /// Consumes a token.
  /// Operands: [choiceId, nextStateId]
  token,

  /// Checks an input boundary (start/eof).
  /// Operands: [kind, nextStateId]
  boundary,

  /// Starts a labeled capture.
  /// Operands: [nameId, nextStateId]
  labelStart,

  /// Ends a labeled capture.
  /// Operands: [nameId, nextStateId]
  labelEnd,

  /// Calls a rule.
  /// Operands: [ruleId, returnStateId, minPrecedence]
  /// Note: minPrecedence uses -1 for null.
  call,

  /// Performs a tail-recursive rule call.
  /// Operands: [ruleId, minPrecedence]
  tailCall,

  /// Returns from a rule call.
  /// Operands: [ruleId, precedenceLevel]
  ret,

  /// Accepts the input.
  /// Operands: []
  accept,

  /// Initiates a lookahead predicate.
  /// Operands: [isAnd, ruleId, nextStateId]
  predicate,

  /// Retreats the parser one position.
  /// Operands: [nextStateId,]
  retreat;

  const BytecodeOp();
}

/// A compiled state machine represented as a flat bytecode instruction stream.
class BytecodeMachine {
  BytecodeMachine({
    required this.bytecode,
    required this.stateOffsets,
    required this.constants,
    required this.initialStates,
  });

  /// The flat array of instructions and operands.
  final Int32List bytecode;

  /// Maps state IDs to their starting offset in [bytecode].
  final Int32List stateOffsets;

  /// Table for non-integer operands (TokenChoices, Strings).
  final ConstantsTable constants;

  /// The IDs of the initial states to start parsing from.
  final Int32List initialStates;
}
