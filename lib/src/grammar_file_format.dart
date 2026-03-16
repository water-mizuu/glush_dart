/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents a Rule definition parsed from a grammar file
class RuleDefinition {
  final String name;
  final PatternExpr pattern;
  final List<String> marks; // optional @mark annotations

  /// Maps each alternative pattern to its precedence level
  /// This is populated during parsing when precedence levels are specified: "6| pattern"
  final Map<PatternExpr, int> precedenceLevels;

  RuleDefinition({
    required this.name,
    required this.pattern,
    this.marks = const [],
    Map<PatternExpr, int>? precedenceLevels,
  }) : precedenceLevels = precedenceLevels ?? {};

  @override
  String toString() => 'Rule($name = $pattern)';
}

/// Base class for pattern expressions in grammar files
sealed class PatternExpr {}

/// Literal token pattern (e.g., 'a', '+', 'hello')
class LiteralPattern extends PatternExpr {
  final String literal;
  final bool isString; // true for quoted strings, false for single char

  LiteralPattern(this.literal, {this.isString = false});

  @override
  String toString() => isString ? '"$literal"' : "'$literal'";
}

/// Character range pattern (e.g., [a-z], [0-9])
class CharRangePattern extends PatternExpr {
  final List<CharRange> ranges;

  CharRangePattern(this.ranges);

  @override
  String toString() => '[${ranges.join('')}]';
}

class CharRange {
  final int startCode;
  final int endCode;

  CharRange(this.startCode, this.endCode);

  @override
  String toString() {
    if (startCode == endCode) {
      return String.fromCharCode(startCode);
    }
    return '${String.fromCharCode(startCode)}-${String.fromCharCode(endCode)}';
  }
}

/// Marker pattern (e.g., \$add)
class MarkerPattern extends PatternExpr {
  final String name;

  MarkerPattern(this.name);

  @override
  String toString() => '\$$name';
}

/// Rule reference pattern (e.g., expr, expr^2, term)
/// The precedenceConstraint is the minimum level required (e.g., 2 in expr^2)
class RuleRefPattern extends PatternExpr {
  final String ruleName;
  final String? mark; // optional @mark annotation
  final int? precedenceConstraint; // optional ^N constraint

  RuleRefPattern(
    this.ruleName, {
    this.mark,
    this.precedenceConstraint,
  });

  @override
  String toString() {
    final base = mark != null ? '$ruleName @$mark' : ruleName;
    if (precedenceConstraint != null) {
      return '$base^$precedenceConstraint';
    }
    return base;
  }
}

/// Sequence pattern (e.g., expr '+' term)
class SequencePattern extends PatternExpr {
  final List<PatternExpr> patterns;

  SequencePattern(this.patterns);

  @override
  String toString() => patterns.join(' >> ');
}

/// Alternation pattern (e.g., '+' | '-' | '*')
class AlternationPattern extends PatternExpr {
  final List<PatternExpr> patterns;

  AlternationPattern(this.patterns);

  @override
  String toString() => patterns.join(' | ');
}

/// Conjunction pattern (e.g., expr & term)
class ConjunctionPattern extends PatternExpr {
  final List<PatternExpr> patterns;

  ConjunctionPattern(this.patterns);

  @override
  String toString() => patterns.join(' & ');
}

/// Repetition pattern (e.g., expr*, term+, number?)
class RepetitionPattern extends PatternExpr {
  final PatternExpr pattern;
  final RepetitionKind kind;

  RepetitionPattern(this.pattern, this.kind);

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

/// Grouped pattern (e.g., (expr '+' term))
class GroupPattern extends PatternExpr {
  final PatternExpr inner;

  GroupPattern(this.inner);

  @override
  String toString() => '($inner)';
}

/// Semantic action placeholder
class ActionExpr {
  final String code; // Dart code snippet

  ActionExpr(this.code);

  @override
  String toString() => '{$code}';
}

/// Complete grammar file
class GrammarFile {
  final String name;
  final List<RuleDefinition> rules;
  final Map<String, List<ActionExpr>> actions; // rule name -> actions

  GrammarFile({
    required this.name,
    required this.rules,
    this.actions = const {},
  });

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
