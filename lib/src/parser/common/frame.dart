import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/sppf.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A [Frame] represents a set of parser states that share the same context.
///
/// When the parser advances past a token, it produces new frames at the next
/// position. Each frame carries a [Context] and a list of target [State]s
/// to be explored from that position using that context.
///
/// **BSPPF fields:**
/// - [sppfNode]: accumulated [IntermediateNode] (or leaf) for the current rule.
/// - [openLabels]: persistent stack of label-start events not yet matched.
/// - [closedLabels]: persistent log of fully-matched label spans for this rule call.
class Frame {
  Frame(
    this.context,
    this.marks, {
    this.sppfNode,
    this.openLabels,
    this.closedLabels,
  }) : nextStates = {};

  /// The shared parsing context for all states in this frame.
  final Context context;

  /// The accumulated mark results for this parse path.
  final LazyGlushList<Mark> marks;

  /// The accumulated BSPPF node for this parse path (null = ε prefix).
  final SppfNode? sppfNode;

  /// Currently-open labels in this derivation path (persistent linked list).
  ///
  /// Pushed by [LabelStartAction], popped (and moved to [closedLabels]) by
  /// [LabelEndAction]. Threading this avoids walking the mark stream to
  /// pair label-open / label-close events.
  final OpenLabel? openLabels;

  /// Labels that were fully closed during this rule call (persistent linked list).
  ///
  /// Drained into [SymbolNode.recordLabel] when [ReturnAction] fires,
  /// giving O(1) label-span queries on the resulting [SymbolNode].
  final ClosedLabel? closedLabels;

  /// The set of states to be processed at the current input position.
  final Set<State> nextStates;

  /// Creates a shallow copy of the frame for targeted exploration.
  Frame copy() => Frame(context, marks,
      sppfNode: sppfNode, openLabels: openLabels, closedLabels: closedLabels);
}
