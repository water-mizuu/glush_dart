/// Grammar file format specification and types
library glush.grammar_file_format;

/// Represents the high-level definition of a single grammar rule.
///
/// A [RuleDefinition] is the primary structural element of a grammar file. It
/// binds a [name] to a [pattern] expression and may be matched and evaluated
/// using labels and identities.
class RuleDefinition {
  /// Creates a rule definition for [name] with the given [pattern].
  RuleDefinition({required this.name, required this.pattern});

  /// The unique name of the rule within the grammar.
  final String name;

  /// The structural pattern that this rule matches.
  final PatternExpr pattern;

  @override
  String toString() {
    return "Rule($name = $pattern)";
  }
}

/// The base interface for all parsing expressions in the grammar AST.
///
/// A [PatternExpr] defines a part of the grammar's structural specification,
/// such as sequences, alternations, repetitions, or literals.
sealed class PatternExpr {}

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

/// Leading `$name` applied to an entire sequence.
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
/// a [precedenceConstraint] for precedence climbing (e.g., `expr^2`).
class RuleRefPattern implements PatternExpr {
  /// Creates a reference to [ruleName].
  const RuleRefPattern(this.ruleName, {this.precedenceConstraint});

  /// The name of the rule being invoked.
  final String ruleName;

  /// The minimum precedence level required for this call to match.
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

/// Pattern wrapped with a precedence level (e.g., "6 | pattern")
/// The precedence level determines how this alternative is prioritized in parsing
class PrecedenceExpr implements PatternExpr {
  const PrecedenceExpr(this.level, this.pattern);
  final int level;
  final PatternExpr pattern;

  @override
  String toString() => "$level:$pattern";
}

/// The top-level container for a compiled grammar file.
///
/// A [GrammarFile] represents the entire content of a `.glush` file, including
/// its [name], and the list of [rules] it defines.
class GrammarFile {
  /// Creates a grammar file container.
  const GrammarFile({required this.name, required this.rules});

  /// The logical name of the grammar.
  final String name;

  /// The complete list of rule definitions in the file.
  final List<RuleDefinition> rules;

  /// Searches for a rule with the specified [name].
  RuleDefinition? findRule(String name) {
    return rules.where((r) => r.name == name).firstOrNull;
  }

  /// The primary entry point for the grammar (the first defined rule).
  RuleDefinition? get startRule => rules.isNotEmpty ? rules.first : null;

  @override
  String toString() => "GrammarFile($name with ${rules.length} rules)";
}
