/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents a Rule definition parsed from a grammar file
class RuleDefinition {
  RuleDefinition({
    required this.name,
    required this.pattern,
    Map<PatternExpr, int>? precedenceLevels,
  }) : precedenceLevels = precedenceLevels ?? {};
  final String name;
  final PatternExpr pattern;

  /// Maps each alternative pattern to its precedence level
  /// This is populated during parsing when precedence levels are specified: "6| pattern"
  final Map<PatternExpr, int> precedenceLevels;

  @override
  String toString() => "Rule($name = $pattern)";
}

/// Base class for pattern expressions in grammar files
sealed class PatternExpr {}

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

/// Rule reference pattern (e.g., expr, expr^2, term)
/// The precedenceConstraint is the minimum level required (e.g., 2 in expr^2)
class RuleRefPattern implements PatternExpr {
  // optional ^N constraint

  const RuleRefPattern(this.ruleName, {this.precedenceConstraint});
  final String ruleName;
  final int? precedenceConstraint;

  @override
  String toString() {
    String base = ruleName;
    if (precedenceConstraint != null) {
      return "$base^$precedenceConstraint";
    }
    return base;
  }
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

/// One-or-more repetition (e.g., expr+)
class PlusPattern implements PatternExpr {
  const PlusPattern(this.pattern);
  final PatternExpr pattern;

  @override
  String toString() => "$pattern+";
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
