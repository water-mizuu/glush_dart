import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

/// A [Frame] represents a set of parser states that share the same context.
///
/// When the parser advances past a token, it produces new frames at the next
/// position. Each frame carries a [Context] and a list of target [State]s
/// to be explored from that position using that context.
class Frame {
  Frame(this.context, this.marks) : nextStates = {};

  /// The shared parsing context for all states in this frame.
  final Context context;

  /// The accumulated results for this parse path.
  final LazyGlushList<Mark> marks;

  /// The set of states to be processed at the current input position.
  final Set<State> nextStates;

  /// Creates a shallow copy of the frame for targeted exploration.
  Frame copy() => Frame(context, marks);
}
