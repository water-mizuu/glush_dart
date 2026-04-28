import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/frame.dart";

/// A version of [Frame] that uses integer state IDs.
class BytecodeFrame {
  const BytecodeFrame(this.context, this.marks, this.stateId);

  final Context context;
  final LazyGlushList<Mark> marks;
  final int stateId;
}
