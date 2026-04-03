import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/helper/ref.dart";
import "package:glush/src/parser/common/context.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:glush/src/parser/common/state_machine.dart";

/// Represents a waiting frame at a rule call site, to be resumed upon completion.
typedef WaiterInfo = (
  State nextState,
  int? minPrecedence,
  Context parentContext,
  Ref<GlushList<Mark>> parentMarks,
  ParseNodeKey callSite,
);
