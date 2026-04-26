import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";

/// A version of [Frame] that uses integer state IDs.
class BytecodeFrame {
  const BytecodeFrame(this.context, this.marks, this._nextStates);

  final Context context;
  final LazyGlushList<Mark> marks;
  final List<int> _nextStates;

  ImmutableListView<int> get nextStates => ImmutableListView(_nextStates);
}

extension type const ImmutableListView<T>(List<T> value) implements Iterable<T> {
  T operator [](int index) => value[index];
}
