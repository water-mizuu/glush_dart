import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/state_machine/state_machine.dart";

// /// A set of parser states that share the same context at a specific position.
// ///
// /// [Frame] is the primary unit of work for the parser's transition loop. When
// /// the parser moves past a token, it calculates the set of reachable next
// /// states. If multiple states share the same [Context], they are grouped into
// /// a single [Frame] to allow for efficient batch processing and merging of
// /// derivation paths.
// ///
// /// A frame acts as a snapshot of a particular parse path's state, including:
// /// - The semantic [marks] collected so far.
extension type const Frame._((Context, LazyGlushList<Mark>, Set<State>) data) {
  const Frame(Context context, LazyGlushList<Mark> marks, Set<State> nextStates)
    : this._((context, marks, nextStates));

  Context get context => data.$1;
  LazyGlushList<Mark> get marks => data.$2;
  Set<State> get nextStates => data.$3;
}
