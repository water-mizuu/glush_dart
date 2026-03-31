import "package:glush/src/core/patterns.dart";
import "package:meta/meta.dart";

/// Key for grouping return contexts by metadata, excluding marks.
@immutable
final class ReturnKey {
  ReturnKey(this.precedenceLevel, this.pivot, this.bsrRuleSymbol, this.callStart)
    : _hash = Object.hash(ReturnKey, precedenceLevel, pivot, bsrRuleSymbol, callStart);

  final int? precedenceLevel;
  final int? pivot;
  final PatternSymbol? bsrRuleSymbol;
  final int? callStart;
  final int _hash;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReturnKey &&
          _hash == other._hash &&
          precedenceLevel == other.precedenceLevel &&
          pivot == other.pivot &&
          bsrRuleSymbol == other.bsrRuleSymbol &&
          callStart == other.callStart;

  @override
  int get hashCode => _hash;
}
