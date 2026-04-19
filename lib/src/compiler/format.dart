/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents the high-level definition of a single grammar rule.
///
/// A [RuleDefinition] is the primary structural element of a grammar file. It
/// binds a [name] to a [pattern] expression and may declare a set of [parameters]
/// that allow the rule to be customized when called from other rules.
class RuleDefinition {
  /// Creates a rule definition for [name] with the given [pattern].
  RuleDefinition({required this.name, required this.pattern, List<String>? parameters})
    : parameters = parameters ?? const [];

  /// The unique name of the rule within the grammar.
  final String name;

  /// The structural pattern that this rule matches.
  final PatternExpr pattern;

  /// The list of parameter names that this rule accepts.
  final List<String> parameters;

  @override
  String toString() {
    var params = parameters.isEmpty ? "" : "(${parameters.join(', ')})";
    return "Rule($name$params = $pattern)";
  }
}

/// The base interface for any value that can be passed as a rule argument.
///
/// This includes both structural [PatternExpr] nodes and data-centric guard
/// expressions (literals, comparisons, etc.).
sealed class CallArgumentValueNode {}

/// The base interface for all parsing expressions in the grammar AST.
///
/// A [PatternExpr] defines a part of the grammar's structural specification,
/// such as sequences, alternations, repetitions, or literals.
sealed class PatternExpr implements CallArgumentValueNode {}

/// Unary expression used in call arguments and guards.
class ExpressionUnaryNode implements CallArgumentValueNode {
  const ExpressionUnaryNode(this.operator, this.operand);
  final ExpressionUnaryOperator operator;
  final CallArgumentValueNode operand;

  @override
  String toString() => "${operator.symbol}$operand";
}

/// Binary expression used in call arguments and guards.
class ExpressionBinaryNode implements CallArgumentValueNode {
  const ExpressionBinaryNode(this.left, this.operator, this.right);
  final CallArgumentValueNode left;
  final ExpressionBinaryOperator operator;
  final CallArgumentValueNode right;

  @override
  String toString() => "$left ${operator.symbol} $right";
}

class ExpressionGroupNode implements CallArgumentValueNode {
  const ExpressionGroupNode(this.inner);
  final CallArgumentValueNode inner;

  @override
  String toString() => "($inner)";
}

/// Postfix member access used in call arguments and guards.
class ExpressionMemberNode implements CallArgumentValueNode {
  const ExpressionMemberNode(this.target, this.member);
  final CallArgumentValueNode target;
  final String member;

  @override
  String toString() => "$target.$member";
}

enum ExpressionUnaryOperator {
  logicalNot("!"),
  negate("-");

  const ExpressionUnaryOperator(this.symbol);
  final String symbol;
}

enum ExpressionBinaryOperator {
  add("+"),
  subtract("-"),
  multiply("*"),
  divide("/"),
  modulo("%"),
  logicalAnd("&&"),
  logicalOr("||"),
  equals("=="),
  notEquals("!="),
  lessThan("<"),
  lessOrEqual("<="),
  greaterThan(">"),
  greaterOrEqual(">=");

  const ExpressionBinaryOperator(this.symbol);
  final String symbol;
}

/// A pattern that matches a literal string or character.
///
/// Literals are the leaf nodes of the grammar that match exact input sequences.
/// Quoted strings in the grammar file are parsed into this expression.
class LiteralPattern implements PatternExpr {
  /// Creates a literal pattern for the given [literal] text.
  const LiteralPattern(this.literal, {this.isString = false});

  /// The literal text to match.
  final String literal;

  /// Whether the literal was parsed from a double-quoted string.
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

/// A pattern that invokes another rule by name.
///
/// Rule references allow for modular and recursive grammar definitions. They
/// can include [arguments] for parameterized rules and a [precedenceConstraint]
/// for precedence climbing (e.g., `expr^2`).
class RuleRefPattern implements PatternExpr {
  /// Creates a reference to [ruleName].
  const RuleRefPattern(this.ruleName, {this.arguments = const [], this.precedenceConstraint});

  /// The name of the rule being invoked.
  final String ruleName;

  /// The arguments provided to the called rule.
  final List<CallArgumentNode> arguments;

  /// The minimum precedence level required for this call to match.
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

/// A pattern that matches multiple sub-patterns in sequence.
///
/// Sequences represent the "followed by" relationship in PEG grammars.
class SequencePattern implements PatternExpr {
  /// Creates a sequence from a list of [patterns].
  const SequencePattern(this.patterns);

  /// The sub-expressions that must match in order.
  final List<PatternExpr> patterns;

  @override
  String toString() => patterns.join(" >> ");
}

/// A pattern that matches any one of several alternatives.
///
/// Alternatives represent the ordered choice ("or") relationship in PEG grammars.
class AlternationPattern implements PatternExpr {
  /// Creates an alternation from a list of [patterns].
  const AlternationPattern(this.patterns);

  /// The sub-expressions to attempt in order.
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

/// A pattern that matches an expression repeatedly.
///
/// This covers common repetitions like `*` (zero or more), `+` (one or more),
/// and `?` (optional).
class RepetitionPattern implements PatternExpr {
  /// Creates a repetition of [pattern] based on [kind].
  const RepetitionPattern(this.pattern, this.kind);

  /// The expression to repeat.
  final PatternExpr pattern;

  /// The quantifier type (*, +, or ?).
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

class RetreatPattern implements PatternExpr {
  const RetreatPattern();

  @override
  String toString() => "<";
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
  final CallArgumentValueNode guard;
  final PatternExpr inner;

  @override
  String toString() => "if ($guard) $inner";
}

/// Base class for guard values used inside comparisons.
sealed class GuardValueNode implements CallArgumentValueNode {}

class GuardBoolLiteralNode implements GuardValueNode {
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

/// Pattern wrapped with a precedence level (e.g., "6 | pattern")
/// The precedence level determines how this alternative is prioritized in parsing
class PrecedenceExpr implements PatternExpr {
  const PrecedenceExpr(this.level, this.pattern);
  final int level;
  final PatternExpr pattern;

  @override
  String toString() => "$level:$pattern";
}

/// Semantic action placeholder
class ActionExpr {
  // Dart code snippet

  const ActionExpr(this.code);
  final String code;

  @override
  String toString() => "{$code}";
}

/// The top-level container for a compiled grammar file.
///
/// A [GrammarFile] represents the entire content of a `.glush` file, including
/// its [name], the list of [rules] it defines, and any top-level [actions].
class GrammarFile {
  /// Creates a grammar file container.
  const GrammarFile({required this.name, required this.rules, this.actions = const {}});

  /// The logical name of the grammar.
  final String name;

  /// The complete list of rule definitions in the file.
  final List<RuleDefinition> rules;

  /// Semantic actions indexed by their associated rule or pattern name.
  final Map<String, List<ActionExpr>> actions;

  /// Searches for a rule with the specified [name].
  RuleDefinition? findRule(String name) {
    return rules.where((r) => r.name == name).firstOrNull;
  }

  /// The primary entry point for the grammar (the first defined rule).
  RuleDefinition? get startRule => rules.isNotEmpty ? rules.first : null;

  @override
  String toString() => "GrammarFile($name with ${rules.length} rules)";
}
