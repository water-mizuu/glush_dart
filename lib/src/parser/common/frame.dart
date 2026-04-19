import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/sppf.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A set of parser states that share the same context at a specific position.
///
/// [Frame] is the primary unit of work for the parser's transition loop. When
/// the parser moves past a token, it calculates the set of reachable next
/// states. If multiple states share the same [Context], they are grouped into
/// a single [Frame] to allow for efficient batch processing and merging of
/// derivation paths.
///
/// A frame acts as a snapshot of a particular parse path's state, including:
/// - The semantic [marks] collected so far.
/// - The partially constructed [sppfNode] (parse forest).
/// - The stack of [openLabels] and log of [closedLabels] for the current rule.
class Frame {
  /// Creates a [Frame] with the given [context] and [marks].
  Frame(
    this.context,
    this.marks, {
    this.sppfNode,
    this.openLabels,
    this.closedLabels,
  }) : nextStates = {};

  /// The shared parsing context (caller, arguments, etc.) for this frame.
  final Context context;

  /// The accumulated semantic values (marks) for this derivation path.
  final LazyGlushList<Mark> marks;

  /// The accumulated BSPPF node representing the parse forest for this path.
  ///
  /// This is null if no input has been consumed yet for the current rule.
  final SppfNode? sppfNode;

  /// The persistent stack of labels that have been started but not yet closed.
  ///
  /// Threading this through the frame allows the parser to pair start and end
  /// markers efficiently without expensive forest traversals.
  final OpenLabel? openLabels;

  /// The persistent log of labels that have been fully matched in this path.
  ///
  /// When a rule finishes, these labels are moved into the final [SymbolNode].
  final ClosedLabel? closedLabels;

  /// The set of state machine states to be explored from this frame.
  final Set<State> nextStates;

  /// Creates a copy of this frame, used when branching the parse path.
  Frame copy() =>
      Frame(context, marks, sppfNode: sppfNode, openLabels: openLabels, closedLabels: closedLabels);
}
