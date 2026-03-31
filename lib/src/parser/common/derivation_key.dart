import "package:glush/src/parser/common/branch_key.dart";
import "package:glush/src/parser/common/parse_node_key.dart";
import "package:meta/meta.dart";

/// Key for tracking one structural derivation edge in ambiguous mode.
///
/// Combines the source location, the specific branch key used, and the call site
/// to uniquely identify a path through the grammar for forest reconstruction.
@immutable
class DerivationKey {
  const DerivationKey(this.source, this.branchKey, this.callSite);
  final ParseNodeKey? source;
  final BranchKey branchKey;
  final ParseNodeKey? callSite;

  @override
  bool operator ==(Object other) =>
      other is DerivationKey &&
      source == other.source &&
      branchKey == other.branchKey &&
      callSite == other.callSite;

  @override
  int get hashCode => Object.hash(source, branchKey, callSite);
}
