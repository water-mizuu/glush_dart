/// Deduplication table for BSPPF nodes.
///
/// All node creation goes through this table to ensure that nodes are shared
/// whenever two derivation paths produce the same (type, start, end) triple.
library glush.sppf_table;

import 'package:glush/src/core/patterns.dart';
import 'package:glush/src/core/sppf.dart';

/// Shared table of BSPPF nodes for a single parse session.
///
/// Keys:
/// - [TerminalNode]   → `position`
/// - [EpsilonNode]    → `position`
/// - [IntermediateNode] → `(slotId, start, end)`
/// - [SymbolNode]     → `(ruleSymbol, start, end)`
class SppfTable {
  // -------------------------------------------------------------------------
  // Internal maps
  // -------------------------------------------------------------------------

  final Map<int, TerminalNode> _terminals = {};
  final Map<int, EpsilonNode> _epsilons = {};

  // Packed as a single int key where possible for speed.
  // Complex key: (slotId, start, end) - use Object.hash
  final Map<int, IntermediateNode> _intermediateSimple = {};
  final Map<Object, IntermediateNode> _intermediateComplex = {};

  final Map<int, SymbolNode> _symbolSimple = {};
  final Map<Object, SymbolNode> _symbolComplex = {};

  // -------------------------------------------------------------------------
  // Public accessors
  // -------------------------------------------------------------------------

  /// Get or create a [TerminalNode] for [position].
  TerminalNode terminal(int position) =>
      _terminals[position] ??= TerminalNode(position);

  /// Get or create an [EpsilonNode] at [position].
  EpsilonNode epsilon(int position) =>
      _epsilons[position] ??= EpsilonNode(position);

  /// Get or create an [IntermediateNode] for ([slotId], [start], [end]).
  IntermediateNode intermediate(int slotId, int start, int end) {
    // Fast path: pack into one int if all values fit.
    if (slotId < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      var key = (slotId << 32) | (start << 16) | end;
      return _intermediateSimple[key] ??= IntermediateNode(slotId, start, end);
    }
    var key = Object.hash(slotId, start, end);
    return _intermediateComplex[key] ??= IntermediateNode(slotId, start, end);
  }

  /// Get or create a [SymbolNode] for ([ruleSymbol], [start], [end]).
  SymbolNode symbol(PatternSymbol ruleSymbol, int start, int end) {
    if (ruleSymbol >= 0 && ruleSymbol < 0xFFFF && start < 0xFFFF && end < 0xFFFF) {
      var key = (ruleSymbol << 32) | (start << 16) | end;
      return _symbolSimple[key] ??= SymbolNode(ruleSymbol, start, end);
    }
    var key = Object.hash(ruleSymbol, start, end);
    return _symbolComplex[key] ??= SymbolNode(ruleSymbol, start, end);
  }

  // -------------------------------------------------------------------------
  // Core construction helpers
  // -------------------------------------------------------------------------

  /// Build or update an [IntermediateNode] for a step transition.
  ///
  /// Called after each child completion (terminal or sub-rule):
  /// - [slotId]: the state ID of the state we are transitioning INTO
  /// - [callStart]: the start position of the enclosing rule call
  /// - [position]: the new input position (right boundary after the child)
  /// - [left]: the accumulated prefix so far (null = ε, first child only)
  /// - [right]: the child just completed
  ///
  /// Returns the shared [IntermediateNode] keyed by (slotId, callStart, position).
  /// Multiple derivation paths add distinct [SppfFamily] entries.
  IntermediateNode getNodeP(
    int slotId,
    int callStart,
    int position,
    SppfNode? left,
    SppfNode right,
  ) {
    var node = intermediate(slotId, callStart, position);
    node.addFamily(left, right);
    return node;
  }

  // -------------------------------------------------------------------------
  // Diagnostics
  // -------------------------------------------------------------------------

  int get terminalCount => _terminals.length;
  int get intermediateCount => _intermediateSimple.length + _intermediateComplex.length;
  int get symbolCount => _symbolSimple.length + _symbolComplex.length;

  /// All [SymbolNode]s created during this parse session.
  ///
  /// Exposed for diagnostic tests that want to walk the BSPPF after parsing.
  Iterable<SymbolNode> get allSymbolNodes =>
      _symbolSimple.values.followedBy(_symbolComplex.values);

  @override
  String toString() =>
      'SppfTable(T=$terminalCount, I=$intermediateCount, S=$symbolCount)';
}
