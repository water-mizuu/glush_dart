import "dart:typed_data";

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/bytecode/bytecode_step.dart";
import "package:glush/src/parser/bytecode/constants_table.dart";

/// Integer opcode constants for the bytecode state machine.
///
/// Using a plain-integer constants class instead of an enum allows the
/// [BytecodeStep._process] dispatch loop to switch directly on [int] values,
/// giving the Dart VM the best chance to emit a native jump-table without any
/// intermediate enum-object materialisation.
///
/// Token opcodes are specialised by [TokenChoice] variant so that matching
/// becomes a single inline integer comparison rather than a constants-table
/// lookup followed by a virtual-dispatch call to [TokenChoice.matches].
/// Every variant also has a negated ("Not") counterpart so that a
/// [NotToken] wrapping any inner choice can be encoded without special-casing
/// in the runtime.
///
/// Operand layouts:
///   tokenExact      [value, nextState]
///   tokenExactNot   [value, nextState]
///   tokenRange      [start, end, nextState]
///   tokenRangeNot   [start, end, nextState]
///   tokenAny        [nextState,]
///   tokenAnyNot     [nextState,]   -- never fires; kept for encoding symmetry
///   tokenLess       [bound, nextState]
///   tokenLessNot    [bound, nextState]
///   tokenGreater    [bound, nextState]
///   tokenGreaterNot [bound, nextState]
///   boundaryStart   [nextState,]
///   boundaryEof     [nextState,]
///   labelStart      [nameId, nextState]
///   labelEnd        [nameId, nextState]
///   call            [ruleId, returnState, minPrec(-1=none), admissOff]
///   tailCall        [ruleId, minPrec(-1=none), admissOff]
///   retSimple       [ruleId,]
///   retPrec         [ruleId, precedenceLevel]
///   accept          []
///   predicate       [isAnd(0|1), ruleId, nextState]
///   retreat         [nextState,]
abstract final class BytecodeOp {
  // --- Token opcodes (specialised by TokenChoice variant) ---

  /// Matches token == value.
  static const int tokenExact = 0;

  /// Matches token != null && token != value.
  static const int tokenExactNot = 1;

  /// Matches token != null && token >= start && token <= end.
  static const int tokenRange = 2;

  /// Matches token != null && (token < start || token > end).
  static const int tokenRangeNot = 3;

  /// Matches token != null (wildcard).
  static const int tokenAny = 4;

  /// Matches nothing (not(any) is always false for non-null tokens).
  /// Operand is still present for uniform offset arithmetic.
  static const int tokenAnyNot = 5;

  /// Matches token != null && token <= bound.
  static const int tokenLess = 6;

  /// Matches token != null && token > bound.
  static const int tokenLessNot = 7;

  /// Matches token != null && token >= bound.
  static const int tokenGreater = 8;

  /// Matches token != null && token < bound.
  static const int tokenGreaterNot = 9;

  // --- Boundary opcodes (split from the former single boundary opcode) ---

  /// Fires when the current position is 0 (start of input).
  static const int boundaryStart = 10;

  /// Fires when the current token is null (end of input).
  static const int boundaryEof = 11;

  // --- Label opcodes ---

  /// Emits a LabelStartVal mark. Operands: [nameId, nextState]
  static const int labelStart = 12;

  /// Emits a LabelEndVal mark. Operands: [nameId, nextState]
  static const int labelEnd = 13;

  // --- Call opcodes ---

  /// Calls a rule with a return address.
  /// Operands: [ruleId, returnState, minPrec(-1=none), admissOff]
  static const int call = 14;

  /// Tail-recursive rule call (no new GSS frame).
  /// Operands: [ruleId, minPrec(-1=none), admissOff]
  static const int tailCall = 15;

  // --- Return opcodes (split to eliminate null checks on the hot path) ---

  /// Returns from a rule with no precedence constraint.
  /// Operands: [ruleId]
  static const int retSimple = 16;

  /// Returns from a rule with a specific precedence level.
  /// Operands: [ruleId, precedenceLevel]
  static const int retPrec = 17;

  // --- Miscellaneous ---

  /// Accepts the input (parse success).
  static const int accept = 18;

  /// Initiates a lookahead predicate (&rule or !rule).
  /// Operands: [isAnd(0|1), ruleId, nextState]
  static const int predicate = 19;

  /// Retreats the parser one position backward.
  /// Operands: [nextState]
  static const int retreat = 20;
}

/// A compiled state machine represented as a flat bytecode instruction stream.
class BytecodeMachine {
  BytecodeMachine({
    required this.bytecode,
    required this.stateOffsets,
    required this.constants,
    required this.initialStates,
    required this.admissibility,
  });

  /// The flat array of instructions and operands.
  final Int32List bytecode;

  /// Maps state IDs to their starting offset in [bytecode].
  final Int32List stateOffsets;

  /// Table for non-integer operands (String label names).
  final ConstantsTable constants;

  /// The IDs of the initial states to start parsing from.
  final Int32List initialStates;

  /// Packed bitset for rule-start admissibility.
  ///
  /// For each rule, 17 consecutive words are stored:
  ///   - Words [offset +  0 ..  +7]: "notAtStart" bitset for tokens 0–255
  ///     (bit `t & 31` of word `t >> 5` is 1 iff the rule can start with
  ///     token `t` when the position is not 0).
  ///   - Words [offset +  8 .. +15]: "atStart" bitset for tokens 0–255.
  ///   - Word  [offset + 16]       : flags — bit 0 = eofNotAtStart,
  ///                                          bit 1 = eofAtStart.
  ///
  /// The per-rule offset is encoded as the last operand of every [call] and
  /// [tailCall] instruction, enabling a direct [Int32List] lookup with no
  /// [HashMap] indirection.
  final Int32List admissibility;
}
