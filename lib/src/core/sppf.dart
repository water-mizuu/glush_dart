/// Binarized Shared Packed Parse Forest (BSPPF) node types.
///
/// Because the Glushkov state machine is already binarized (S ::= A B C is
/// compiled as S ::= ((A B) C) implicitly through the state chain), each
/// [IntermediateNode] maps directly to a state-machine slot (state ID).
/// No explicit re-binarization is required.
library glush.sppf;

import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

// ---------------------------------------------------------------------------
// Node hierarchy
// ---------------------------------------------------------------------------

/// Base class for all BSPPF nodes.
@immutable
sealed class SppfNode {
  const SppfNode();

  int get start;
  int get end;
}

// ---------------------------------------------------------------------------
// Leaf nodes
// ---------------------------------------------------------------------------

/// A single consumed input token at [position].
class TerminalNode extends SppfNode {
  const TerminalNode(this.position);

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

/// An epsilon (zero-width) derivation at [position].
class EpsilonNode extends SppfNode {
  const EpsilonNode(this.position);

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

/// A family entry inside an [IntermediateNode] or [SymbolNode].
///
/// Represents one binary split: [left] is the accumulated prefix (null = ε),
/// [right] is the child just completed (null = ε body in a SymbolNode).
class SppfFamily {
  const SppfFamily(this.left, this.right);

  /// Accumulated left prefix (previous IntermediateNode or null).
  final SppfNode? left;

  /// Rightmost child (TerminalNode, SymbolNode, IntermediateNode, or null for ε).
  final SppfNode? right;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SppfFamily && identical(left, other.left) && identical(right, other.right));

  @override
  int get hashCode => Object.hash(identityHashCode(left), identityHashCode(right));
}

/// An intermediate node keyed by [slotId] (state ID) and span [start]..[end].
///
/// Represents everything parsed in a rule up to—but not including—the final
/// return. Multiple derivations contribute distinct [SppfFamily] entries.
// ignore: must_be_immutable
class IntermediateNode extends SppfNode {
  IntermediateNode(this.slotId, this.start, this.end);

  /// The state-machine state ID that identifies this slot.
  final int slotId;

  @override
  final int start;

  @override
  final int end;

  /// All derivation alternatives for this slot+span.
  final List<SppfFamily> families = [];

  /// Add a derivation alternative (deduplicates by identity).
  void addFamily(SppfNode? left, SppfNode right) {
    var f = SppfFamily(left, right);
    if (!families.contains(f)) {
      families.add(f);
    }
  }

  @override
  String toString() => "Intermediate(slot=$slotId, $start..$end, #${families.length})";
}

/// A symbol node keyed by [ruleSymbol] and span [start]..[end].
///
/// Represents a complete derivation of a grammar rule. All frames that
/// complete [ruleSymbol] over the same span share this node.
// ignore: must_be_immutable
class SymbolNode extends SppfNode {
  SymbolNode(this.ruleSymbol, this.start, this.end);

  final PatternSymbol ruleSymbol;

  @override
  final int start;

  @override
  final int end;

  /// One entry per derivation alternative.
  ///
  /// Each body is the accumulated [IntermediateNode] (or a leaf node) that
  /// represents one complete parse of this rule's right-hand side.
  final List<SppfNode?> families = [];

  /// Add a body derivation (deduplicates by identity).
  void addFamily(SppfNode? body) {
    for (var existing in families) {
      if (identical(existing, body)) return;
    }
    families.add(body);
  }

  // ---------------------------------------------------------------------------
  // Label index
  // ---------------------------------------------------------------------------

  /// Labels closed during derivations of this rule.
  ///
  /// Keyed by label name → list of (start, end) spans, one per derivation
  /// path that closed that label. Populated eagerly during [_processReturnAction]
  /// so that post-parse queries are O(1) map lookups.
  Map<String, List<(int start, int end)>>? _labelMap;

  /// Record that label [name] spans [[start]..[end]] in one derivation of this rule.
  void recordLabel(String name, int start, int end) {
    (_labelMap ??= {})[name] ??= [];
    var list = _labelMap![name]!;
    // Deduplicate identical spans (different derivation paths may produce the same span).
    for (var entry in list) {
      if (entry.$1 == start && entry.$2 == end) return;
    }
    list.add((start, end));
  }

  /// All label spans for [name] across all derivations of this rule.
  /// Returns an empty list if the label was never recorded.
  List<(int start, int end)> labelsFor(String name) =>
      _labelMap?[name] ?? const [];

  /// The first (or only) span for [name], or null if absent.
  (int start, int end)? labelFor(String name) => _labelMap?[name]?.firstOrNull;

  /// Raw label map — exposed for diagnostic tests only.
  ///
  /// Returns null if no labels were recorded for this node.
  Map<String, List<(int start, int end)>>? get labelMapForDebug => _labelMap;

  @override
  String toString() {
    final labels = _labelMap?.length ?? 0;
    return "Symbol($ruleSymbol, $start..$end, #${families.length}, labels=$labels)";
  }
}

// ---------------------------------------------------------------------------
// Label-tracking linked lists  (threaded through Frame during parsing)
// ---------------------------------------------------------------------------

/// One entry in the open-label stack: a label that has been started but not yet closed.
///
/// This is a persistent linked list threaded through [Frame] so that
/// [_processLabelEndAction] can pair each close with its matching open
/// without walking the mark stream.
class OpenLabel {
  const OpenLabel(this.name, this.openPos, this.tail);

  final String name;
  final int openPos;
  final OpenLabel? tail;

  /// Return a new stack with this entry appended at the top.
  OpenLabel push(String name, int pos) => OpenLabel(name, pos, this);
}

/// One entry in the closed-label log: a fully matched label span.
///
/// A persistent linked list of all labels closed during the current rule call.
/// Attached to a [SymbolNode] in batch when [_processReturnAction] fires.
class ClosedLabel {
  const ClosedLabel(this.name, this.start, this.end, this.tail);

  final String name;
  final int start;
  final int end;
  final ClosedLabel? tail;
}

/// Pop the topmost [name] entry from [stack], returning the new stack and
/// the open position.  Returns null if [name] is not found (malformed input).
(OpenLabel? newStack, int openPos)? popOpenLabel(OpenLabel? stack, String name) {
  if (stack == null) return null;
  if (stack.name == name) return (stack.tail, stack.openPos);
  var result = popOpenLabel(stack.tail, name);
  if (result == null) return null;
  // Reconstruct the prefix above the popped entry.
  return (OpenLabel(stack.name, stack.openPos, result.$1), result.$2);
}

