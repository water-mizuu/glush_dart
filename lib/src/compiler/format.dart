/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents a Rule definition parsed from a grammar file
class RuleDefinition {
  RuleDefinition({
    required this.name,
    required this.pattern,
    List<String>? parameters,
    Map<PatternExpr, int>? precedenceLevels,
  }) : parameters = parameters ?? const [],
       precedenceLevels = precedenceLevels ?? {};
  final String name;
  final PatternExpr pattern;
  final List<String> parameters;

  /// Maps each alternative pattern to its precedence level
  /// This is populated during parsing when precedence levels are specified: "6| pattern"
  final Map<PatternExpr, int> precedenceLevels;

  @override
  String toString() {
    var params = parameters.isEmpty ? "" : "(${parameters.join(', ')})";
    return "Rule($name$params = $pattern)";
  }
}

/// Base class for pattern expressions in grammar files
sealed class CallArgumentValueNode {}

sealed class PatternExpr implements CallArgumentValueNode {}

/// Literal token pattern (e.g., 'a', '+', 'hello')
class LiteralPattern implements PatternExpr {
  // true for quoted strings, false for single char

  const LiteralPattern(this.literal, {this.isString = false});
  final String literal;
  final bool isString;

  @override
  String toString() => isString ? '"$literal"' : "'$literal'";
}

/// Character range pattern (e.g., [a-z], [0-9])
class CharRangePattern implements PatternExpr {
  const CharRangePattern(this.ranges);
  final List<CharRange> ranges;

  @override
  String toString() => "[${ranges.join()}]";
}

/// Backslash literal pattern (e.g., \n, \r, \s, \S)
class BackslashLiteralPattern implements PatternExpr {
  const BackslashLiteralPattern(this.char);
  final String char;

  @override
  String toString() => "\\$char";
}

class CharRange {
  const CharRange(this.startCode, this.endCode);
  final int startCode;
  final int endCode;

  @override
  String toString() {
    if (startCode == endCode) {
      return String.fromCharCode(startCode);
    }
    return "${String.fromCharCode(startCode)}-${String.fromCharCode(endCode)}";
  }
}

class LessThanPattern implements PatternExpr {
  const LessThanPattern(this.codePoint);
  final int codePoint;

  @override
  String toString() => "<$codePoint";
}

class GreaterThanPattern implements PatternExpr {
  const GreaterThanPattern(this.codePoint);
  final int codePoint;

  @override
  String toString() => ">=$codePoint";
}

/// Marker pattern (e.g., \$add)
class MarkerPattern implements PatternExpr {
  const MarkerPattern(this.name);
  final String name;

  @override
  String toString() => "\$$name";
}

/// Leading `$name` applied to an entire sequence.
///
/// This is distinct from [MarkerPattern], which represents a `$name` used as a
/// standalone primary expression inside a sequence.
class MainMarkPattern implements PatternExpr {
  const MainMarkPattern(this.name, this.inner);
  final String name;
  final PatternExpr inner;

  @override
  String toString() => "\$$name $inner";
}

/// Rule reference pattern (e.g., expr, expr^2, term)
/// The precedenceConstraint is the minimum level required (e.g., 2 in expr^2)
class RuleRefPattern implements PatternExpr {
  // optional ^N constraint

  const RuleRefPattern(this.ruleName, {this.arguments = const [], this.precedenceConstraint});
  final String ruleName;
  final List<CallArgumentNode> arguments;
  final int? precedenceConstraint;

  @override
  String toString() {
    String base = ruleName;
    if (arguments.isNotEmpty) {
      base += "(${arguments.join(', ')})";
    }
    if (precedenceConstraint != null) {
      return "$base^$precedenceConstraint";
    }
    return base;
  }
}

class CallArgumentNode {
  const CallArgumentNode(this.value, {this.name});
  final String? name;
  final CallArgumentValueNode value;

  @override
  String toString() => name == null ? "$value" : "$name: $value";
}

/// Sequence pattern (e.g., expr '+' term)
class SequencePattern implements PatternExpr {
  const SequencePattern(this.patterns);
  final List<PatternExpr> patterns;

  @override
  String toString() => patterns.join(" >> ");
}

/// Alternation pattern (e.g., '+' | '-' | '*')
class AlternationPattern implements PatternExpr {
  const AlternationPattern(this.patterns);
  final List<PatternExpr> patterns;

  @override
  String toString() => patterns.join(" | ");
}

/// Conjunction pattern (e.g., expr & term)
class ConjunctionPattern implements PatternExpr {
  const ConjunctionPattern(this.patterns);
  final List<PatternExpr> patterns;

  @override
  String toString() => patterns.join(" & ");
}

/// Repetition pattern (e.g., expr*, term+, number?)
class RepetitionPattern implements PatternExpr {
  const RepetitionPattern(this.pattern, this.kind);
  final PatternExpr pattern;
  final RepetitionKind kind;

  @override
  String toString() => "$pattern${kind.suffix}";
}

/// Zero-or-more repetition (e.g., expr*)
class StarPattern implements PatternExpr {
  const StarPattern(this.pattern);
  final PatternExpr pattern;

  @override
  String toString() => "$pattern*";
}

class StarBangPattern implements PatternExpr {
  const StarBangPattern(this.pattern);
  final PatternExpr pattern;

  @override
  String toString() => "$pattern*!";
}

/// One-or-more repetition (e.g., expr+)
class PlusPattern implements PatternExpr {
  const PlusPattern(this.pattern);
  final PatternExpr pattern;

  @override
  String toString() => "$pattern+";
}

class PlusBangPattern implements PatternExpr {
  const PlusBangPattern(this.pattern);
  final PatternExpr pattern;

  @override
  String toString() => "$pattern+!";
}

enum RepetitionKind {
  zeroOrMore("*"),
  oneOrMore("+"),
  optional("?");

  const RepetitionKind(this.suffix);

  final String suffix;
}

/// Predicate pattern (e.g., &expr, !expr)
class PredicatePattern implements PatternExpr {
  const PredicatePattern(this.pattern, {required this.isAnd});
  final PatternExpr pattern;
  final bool isAnd;

  @override
  String toString() => '${isAnd ? '&' : '!'}$pattern';
}

/// Grouped pattern (e.g., (expr '+' term))
class GroupPattern implements PatternExpr {
  const GroupPattern(this.inner);
  final PatternExpr inner;

  @override
  String toString() => "($inner)";
}

class AnyPattern implements PatternExpr {
  const AnyPattern();
}

/// Beginning-of-stream anchor.
class StartPattern implements PatternExpr {
  const StartPattern();

  @override
  String toString() => "^";
}

/// End-of-stream anchor.
class EofPattern implements PatternExpr {
  const EofPattern();

  @override
  String toString() => r"$";
}

/// Labeled pattern (e.g., name:ident)
class LabeledPattern implements PatternExpr {
  const LabeledPattern(this.label, this.inner);
  final String label;
  final PatternExpr inner;

  @override
  String toString() => "$label:$inner";
}

/// Guarded sequence prefix (e.g., `if (count > 2) expr`)
class IfPattern implements PatternExpr {
  const IfPattern(this.guard, this.inner);
  final GuardExprNode guard;
  final PatternExpr inner;

  @override
  String toString() => "if ($guard) $inner";
}

/// Base class for boolean guard expressions inside `if (...)`.
sealed class GuardExprNode {}

/// Base class for guard values used inside comparisons.
sealed class GuardValueNode implements CallArgumentValueNode {}

class GuardBoolLiteralNode implements GuardExprNode, GuardValueNode {
  // ignore: avoid_positional_boolean_parameters
  const GuardBoolLiteralNode(this.value);
  final bool value;

  @override
  String toString() => "$value";
}

class GuardNumberLiteralNode implements GuardValueNode {
  const GuardNumberLiteralNode(this.value);
  final num value;

  @override
  String toString() => "$value";
}

class GuardStringLiteralNode implements GuardValueNode {
  const GuardStringLiteralNode(this.value);
  final String value;

  @override
  String toString() => '"$value"';
}

class GuardNameNode implements GuardValueNode {
  const GuardNameNode(this.name);
  final String name;

  @override
  String toString() => name;
}

class GuardRuleNode implements GuardValueNode {
  const GuardRuleNode();

  @override
  String toString() => "rule";
}

class GuardNotNode implements GuardExprNode {
  const GuardNotNode(this.child);
  final GuardExprNode child;

  @override
  String toString() => "!$child";
}

class GuardAndNode implements GuardExprNode {
  const GuardAndNode(this.left, this.right);
  final GuardExprNode left;
  final GuardExprNode right;

  @override
  String toString() => "($left && $right)";
}

class GuardOrNode implements GuardExprNode {
  const GuardOrNode(this.left, this.right);
  final GuardExprNode left;
  final GuardExprNode right;

  @override
  String toString() => "($left || $right)";
}

enum GuardComparisonKind {
  equals("=="),
  notEquals("!="),
  lessThan("<"),
  lessOrEqual("<="),
  greaterThan(">"),
  greaterOrEqual(">=");

  const GuardComparisonKind(this.symbol);
  final String symbol;
}

class GuardComparisonNode implements GuardExprNode {
  const GuardComparisonNode(this.left, this.kind, this.right);
  final GuardValueNode left;
  final GuardComparisonKind kind;
  final GuardValueNode right;

  @override
  String toString() => "$left ${kind.symbol} $right";
}

class GuardValueExprNode implements GuardExprNode {
  const GuardValueExprNode(this.value);
  final GuardValueNode value;

  @override
  String toString() => "$value";
}

/// Semantic action placeholder
class ActionExpr {
  // Dart code snippet

  const ActionExpr(this.code);
  final String code;

  @override
  String toString() => "{$code}";
}

/// Complete grammar file
class GrammarFile {
  // rule name -> actions

  const GrammarFile({required this.name, required this.rules, this.actions = const {}});
  final String name;
  final List<RuleDefinition> rules;
  final Map<String, List<ActionExpr>> actions;

  /// Find a rule by name
  RuleDefinition? findRule(String name) {
    return rules.where((r) => r.name == name).firstOrNull;
  }

  /// Get the start rule (first rule defined)
  RuleDefinition? get startRule => rules.isNotEmpty ? rules.first : null;

  @override
  String toString() => "GrammarFile($name with ${rules.length} rules)";
}
