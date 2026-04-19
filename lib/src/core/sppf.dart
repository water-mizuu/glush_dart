/// Binarized Shared Packed Parse Forest (BSPPF) node types.
///
/// Because the Glushkov state machine is already binarized (S ::= A B C is
/// compiled as S ::= ((A B) C) implicitly through the state chain), each
/// [IntermediateNode] maps directly to a state-machine slot (state ID).
/// No explicit re-binarization is required.
library glush.sppf;

import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/common/frame.dart" show Frame;
import "package:meta/meta.dart";

// ---------------------------------------------------------------------------
// Node hierarchy
// ---------------------------------------------------------------------------

/// Base class for all nodes in the Binarized Shared Packed Parse Forest (BSPPF).
///
/// An SPPF is a data structure that represents all possible parse trees for an
/// ambiguous grammar in a compact, shared format. Glush uses a binarized
/// version where each interior node has at most two children, aligning
/// naturally with the Glushkov state machine's transitions.
@immutable
sealed class SppfNode {
  /// Base constructor for [SppfNode].
  const SppfNode();

  /// The absolute starting position of this node in the input stream (inclusive).
  int get start;

  /// The absolute ending position of this node in the input stream (exclusive).
  int get end;
}

// ---------------------------------------------------------------------------
// Leaf nodes
// ---------------------------------------------------------------------------

/// A leaf node representing a single consumed token from the input stream.
class TerminalNode extends SppfNode {
  /// Creates a [TerminalNode] at the given [position].
  const TerminalNode(this.position);

  /// The position of the token in the input stream.
  final int position;

  @override
  int get start => position;

  @override
  int get end => position + 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is TerminalNode && position == other.position);

  @override
  int get hashCode => position.hashCode ^ 0x54657256;

  @override
  String toString() => "Terminal($position)";
}

/// A leaf node representing an epsilon (zero-width) match at a specific position.
///
/// Epsilon nodes are used for patterns that match without consuming any input,
/// such as optional components that are absent or empty repetitions.
class EpsilonNode extends SppfNode {
  /// Creates an [EpsilonNode] at the given [position].
  const EpsilonNode(this.position);

  /// The position where the epsilon match occurred.
  final int position;

  @override
  int get start => position;

  @override
  int get end => position;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is EpsilonNode && position == other.position);

  @override
  int get hashCode => position.hashCode ^ 0xE510001;

  @override
  String toString() => "Epsilon($position)";
}

// ---------------------------------------------------------------------------
// Interior nodes (shared)
// ---------------------------------------------------------------------------

/// A derivation alternative within an [IntermediateNode] or [SymbolNode].
///
/// In a binarized forest, each interior node represents a concatenation of a
/// [left] prefix and a [right] child. If a node is ambiguous, it will contain
/// multiple [SppfFamily] entries, each representing a different way to split
/// the span or a different derivation path.
@immutable
class SppfFamily {
  /// Creates an [SppfFamily] with the given [left] and [right] children.
  const SppfFamily(this.left, this.right);

  /// The accumulated left prefix, usually an [IntermediateNode] or null.
  final SppfNode? left;

  /// The rightmost child in this binary split, or null for epsilon bodies.
  final SppfNode? right;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SppfFamily && identical(left, other.left) && identical(right, other.right));

  @override
  int get hashCode => Object.hash(identityHashCode(left), identityHashCode(right));
}

/// An interior node representing a partially completed rule body.
///
/// [IntermediateNode]s are keyed by their [slotId] (which corresponds to a
/// state in the Glushkov automaton) and their input span. They act as "packed
/// nodes" in the SPPF, aggregating all possible ways to reach a specific
/// state over a specific span.
// ignore: must_be_immutable
class IntermediateNode extends SppfNode {
  /// Creates an [IntermediateNode] for the given [slotId] and span.
  IntermediateNode(this.slotId, this.start, this.end);

  /// The ID of the state machine slot this node represents.
  final int slotId;

  @override
  final int start;

  @override
  final int end;

  /// Optimized storage for the common case where a node is not ambiguous.
  SppfFamily? _singleFamily;

  /// Storage for multiple derivations in ambiguous cases.
  List<SppfFamily>? _multipleFamilies;

  /// Returns all derivation alternatives for this intermediate node.
  List<SppfFamily> get families {
    if (_multipleFamilies != null) {
      return _multipleFamilies!;
    }
    if (_singleFamily != null) {
      return [_singleFamily!];
    }
    return const [];
  }

  /// Adds a new [SppfFamily] to this node, handling deduplication.
  ///
  /// This method automatically transitions the node from single-family
  /// optimization to multi-family storage if an ambiguous derivation is found.
  void addFamily(SppfNode? left, SppfNode right) {
    var f = SppfFamily(left, right);

    if (_multipleFamilies != null) {
      if (!_multipleFamilies!.contains(f)) {
        _multipleFamilies!.add(f);
      }
    } else if (_singleFamily == null) {
      _singleFamily = f;
    } else if (_singleFamily != f) {
      _multipleFamilies = [_singleFamily!, f];
      _singleFamily = null;
    }
  }

  @override
  String toString() => "Intermediate(slot=$slotId, $start..$end, #${families.length})";
}

/// An interior node representing a completely derived grammar rule.
///
/// [SymbolNode]s are the roots of rule derivations. They are keyed by the
/// [ruleSymbol] and the input span. Like intermediate nodes, they aggregate
/// all possible derivations (bodies) of the rule over that span.
// ignore: must_be_immutable
class SymbolNode extends SppfNode {
  /// Creates a [SymbolNode] for the given [ruleSymbol] and span.
  SymbolNode(this.ruleSymbol, this.start, this.end);

  /// The symbol of the grammar rule this node represents.
  final PatternSymbol ruleSymbol;

  @override
  final int start;

  @override
  final int end;

  /// Optimized storage for non-ambiguous rule derivations.
  SppfNode? _singleFamily;

  /// Storage for ambiguous rule derivations.
  List<SppfNode?>? _multipleFamilies;

  /// Returns all derivation alternatives (rule bodies) for this symbol node.
  List<SppfNode?> get families {
    if (_multipleFamilies != null) {
      return _multipleFamilies!;
    }
    if (_singleFamily != null) {
      return [_singleFamily];
    }
    return const [];
  }

  /// Adds a new derivation body to this node, handling deduplication.
  void addFamily(SppfNode? body) {
    if (_multipleFamilies != null) {
      for (var existing in _multipleFamilies!) {
        if (identical(existing, body)) {
          return;
        }
      }
      _multipleFamilies!.add(body);
    } else if (_singleFamily == null) {
      _singleFamily = body;
    } else if (!identical(_singleFamily, body)) {
      _multipleFamilies = [_singleFamily, body];
      _singleFamily = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Label index
  // ---------------------------------------------------------------------------

  /// Map of label names to their spans captured during the derivation.
  Map<String, List<(int start, int end)>>? _labelMap;

  /// Records a captured label [name] for a specific derivation path.
  ///
  /// Deduplicates identical spans to keep the index compact even if multiple
  /// ambiguous paths produce the same capture.
  void recordLabel(String name, int start, int end) {
    (_labelMap ??= {})[name] ??= [];
    var list = _labelMap![name]!;
    for (var entry in list) {
      if (entry.$1 == start && entry.$2 == end) {
        return;
      }
    }
    list.add((start, end));
  }

  /// Returns all spans captured for [name] in this rule's derivations.
  List<(int start, int end)> labelsFor(String name) => _labelMap?[name] ?? const [];

  /// Returns the primary (first) span for [name], or null if absent.
  (int start, int end)? labelFor(String name) => _labelMap?[name]?.firstOrNull;

  /// Returns the internal label map for diagnostic purposes.
  Map<String, List<(int start, int end)>>? get labelMapForDebug => _labelMap;

  @override
  String toString() {
    var labels = _labelMap?.length ?? 0;
    return "Symbol($ruleSymbol, $start..$end, #${families.length}, labels=$labels)";
  }
}

// ---------------------------------------------------------------------------
// Label-tracking linked lists
// ---------------------------------------------------------------------------

/// A node in a persistent linked list tracking currently open labels.
///
/// As the parser traverses the grammar, it maintains a stack of labels that
/// have been started but not yet closed. Using a persistent list allows each
/// [Frame] to have its own independent view of the label stack.
class OpenLabel {
  /// Creates an [OpenLabel] entry.
  const OpenLabel(this.name, this.openPos, this.tail);

  /// The name of the label.
  final String name;

  /// The position in the input where the label started.
  final int openPos;

  /// The previous entry in the stack.
  final OpenLabel? tail;

  /// Returns a new [OpenLabel] stack with a new entry added.
  OpenLabel push(String name, int pos) => OpenLabel(name, pos, this);
}

/// A node in a persistent linked list tracking closed labels within a rule.
///
/// Once a label is closed, its span is recorded. This list is collected and
/// moved into the [SymbolNode] once the rule derivation is complete.
class ClosedLabel {
  /// Creates a [ClosedLabel] entry.
  const ClosedLabel(this.name, this.start, this.end, this.tail);

  /// The name of the label.
  final String name;

  /// The absolute starting position.
  final int start;

  /// The absolute ending position.
  final int end;

  /// The previous entry in the list.
  final ClosedLabel? tail;
}

/// Helper to pop a specific [name] from an [OpenLabel] stack.
///
/// Since labels might be nested or interleaved in complex ways, this performs
/// a recursive search and reconstruction to remove the correct entry while
/// preserving the rest of the persistent stack.
(OpenLabel? newStack, int openPos)? popOpenLabel(OpenLabel? stack, String name) {
  if (stack == null) {
    return null;
  }
  if (stack.name == name) {
    return (stack.tail, stack.openPos);
  }
  var result = popOpenLabel(stack.tail, name);
  if (result == null) {
    return null;
  }
  return (OpenLabel(stack.name, stack.openPos, result.$1), result.$2);
}
