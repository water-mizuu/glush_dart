/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents a Rule definition parsed from a grammar file
class RuleDefinition {
  final String name;
  final PatternExpr pattern;

  /// Maps each alternative pattern to its precedence level
  /// This is populated during parsing when precedence levels are specified: "6| pattern"
  final Map<PatternExpr, int> precedenceLevels;

  RuleDefinition({
    required this.name,
    required this.pattern,
    Map<PatternExpr, int>? precedenceLevels,
  }) : precedenceLevels = precedenceLevels ?? {};

  @override
  String toString() => 'Rule($name = $pattern)';
}

/// Base class for pattern expressions in grammar files
sealed class PatternExpr {}

/// Literal token pattern (e.g., 'a', '+', 'hello')
class LiteralPattern implements PatternExpr {
  final String literal;
  final bool isString; // true for quoted strings, false for single char

  const LiteralPattern(this.literal, {this.isString = false});

  @override
  String toString() => isString ? '"$literal"' : "'$literal'";
}

/// Character range pattern (e.g., [a-z], [0-9])
class CharRangePattern implements PatternExpr {
  final List<CharRange> ranges;

  const CharRangePattern(this.ranges);

  @override
  String toString() => '[${ranges.join('')}]';
}

/// Backslash literal pattern (e.g., \n, \r, \s, \S)
class BackslashLiteralPattern implements PatternExpr {
  final String char;

  const BackslashLiteralPattern(this.char);

  @override
  String toString() => '\\$char';
}

class CharRange {
  final int startCode;
  final int endCode;

  const CharRange(this.startCode, this.endCode);

  @override
  String toString() {
    if (startCode == endCode) {
      return String.fromCharCode(startCode);
    }
    return '${String.fromCharCode(startCode)}-${String.fromCharCode(endCode)}';
  }
}

class LessThanPattern implements PatternExpr {
  final int codePoint;

  const LessThanPattern(this.codePoint);

  @override
  String toString() => '<$codePoint';
}

class GreaterThanPattern implements PatternExpr {
  final int codePoint;

  const GreaterThanPattern(this.codePoint);

  @override
  String toString() => '>=$codePoint';
}

/// Marker pattern (e.g., \$add)
class MarkerPattern implements PatternExpr {
  final String name;

  const MarkerPattern(this.name);

  @override
  String toString() => '\$$name';
}

/// Rule reference pattern (e.g., expr, expr^2, term)
/// The precedenceConstraint is the minimum level required (e.g., 2 in expr^2)
class RuleRefPattern implements PatternExpr {
  final String ruleName;
  final int? precedenceConstraint; // optional ^N constraint

  const RuleRefPattern(this.ruleName, {this.precedenceConstraint});

  @override
  String toString() {
    String base = ruleName;
    if (precedenceConstraint != null) {
      return '$base^$precedenceConstraint';
    }
    return base;
  }
}

/// Sequence pattern (e.g., expr '+' term)
class SequencePattern implements PatternExpr {
  final List<PatternExpr> patterns;

  const SequencePattern(this.patterns);

  @override
  String toString() => patterns.join(' >> ');
}

/// Alternation pattern (e.g., '+' | '-' | '*')
class AlternationPattern implements PatternExpr {
  final List<PatternExpr> patterns;

  const AlternationPattern(this.patterns);

  @override
  String toString() => patterns.join(' | ');
}

/// Conjunction pattern (e.g., expr & term)
class ConjunctionPattern implements PatternExpr {
  final List<PatternExpr> patterns;

  const ConjunctionPattern(this.patterns);

  @override
  String toString() => patterns.join(' & ');
}

/// Repetition pattern (e.g., expr*, term+, number?)
class RepetitionPattern implements PatternExpr {
  final PatternExpr pattern;
  final RepetitionKind kind;

  const RepetitionPattern(this.pattern, this.kind);

  @override
  String toString() => '$pattern${kind.suffix}';
}

enum RepetitionKind {
  zeroOrMore('*'),
  oneOrMore('+'),
  optional('?');

  final String suffix;
  const RepetitionKind(this.suffix);
}

/// Predicate pattern (e.g., &expr, !expr)
class PredicatePattern implements PatternExpr {
  final PatternExpr pattern;
  final bool isAnd;

  const PredicatePattern(this.pattern, {required this.isAnd});

  @override
  String toString() => '${isAnd ? '&' : '!'}$pattern';
}

/// Grouped pattern (e.g., (expr '+' term))
class GroupPattern implements PatternExpr {
  final PatternExpr inner;

  const GroupPattern(this.inner);

  @override
  String toString() => '($inner)';
}

class AnyPattern implements PatternExpr {
  const AnyPattern();
}

/// Labeled pattern (e.g., name:ident)
class LabeledPattern implements PatternExpr {
  final String label;
  final PatternExpr inner;

  const LabeledPattern(this.label, this.inner);

  @override
  String toString() => '$label:$inner';
}

/// Semantic action placeholder
class ActionExpr {
  final String code; // Dart code snippet

  const ActionExpr(this.code);

  @override
  String toString() => '{$code}';
}

/// Complete grammar file
class GrammarFile {
  final String name;
  final List<RuleDefinition> rules;
  final Map<String, List<ActionExpr>> actions; // rule name -> actions

  const GrammarFile({required this.name, required this.rules, this.actions = const {}});

  /// Find a rule by name
  RuleDefinition? findRule(String name) {
    try {
      return rules.firstWhere((r) => r.name == name);
    } catch (_) {
      return null;
    }
  }

  /// Get the start rule (first rule defined)
  RuleDefinition? get startRule => rules.isNotEmpty ? rules.first : null;

  @override
  String toString() => 'GrammarFile($name with ${rules.length} rules)';
}
