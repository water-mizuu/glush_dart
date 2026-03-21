/// Compiles a parsed grammar file into an executable Grammar
library glush.grammar_file_compiler;

import 'package:glush/src/grammar_file_parser.dart';
import 'package:glush/src/sm_parser.dart';

import 'grammar_file_format.dart';
import 'patterns.dart';
import 'grammar.dart';

/// Compiles a GrammarFile into an executable Grammar
class GrammarFileCompiler {
  final GrammarFile grammarFile;
  late final Map<String, Rule> _rules = {};

  GrammarFileCompiler(this.grammarFile);

  /// Compile the grammar file into an executable Grammar
  Grammar compile() {
    // First pass: create rule stubs with builder functions
    for (final ruleDef in grammarFile.rules) {
      final rule = Rule(ruleDef.name, () {
        return _compilePattern(ruleDef.pattern, ruleDef.precedenceLevels);
      });
      _rules[ruleDef.name] = rule;
    }

    // Return grammar with the first rule as the start rule
    if (grammarFile.rules.isEmpty) {
      throw Exception('No rules defined in grammar');
    }

    final startRule = _rules[grammarFile.rules.first.name]!;
    return Grammar(() => startRule);
  }

  /// Compile a pattern expression into a Pattern
  Pattern _compilePattern(PatternExpr expr, Map<PatternExpr, int> precedenceLevels) {
    switch (expr) {
      case LiteralPattern():
        return Pattern.string(expr.literal);

      case CharRangePattern():
        final ranges = expr.ranges;
        if (ranges.length == 1) {
          final range = ranges[0];
          return Token(RangeToken(range.startCode, range.endCode));
        }
        // Multiple ranges: use alternation
        Pattern result = Token(RangeToken(ranges[0].startCode, ranges[0].endCode));
        for (int i = 1; i < ranges.length; i++) {
          result = result | Token(RangeToken(ranges[i].startCode, ranges[i].endCode));
        }
        return result;

      case MarkerPattern():
        return Marker(expr.name);

      case RuleRefPattern():
        final rule = _rules[expr.ruleName];
        if (rule == null) {
          throw Exception('Undefined rule: ${expr.ruleName}');
        }
        return Call(rule, minPrecedenceLevel: expr.precedenceConstraint);

      case SequencePattern():
        Pattern result = _compilePattern(expr.patterns[0], precedenceLevels);
        for (int i = 1; i < expr.patterns.length; i++) {
          result = result >> _compilePattern(expr.patterns[i], precedenceLevels);
        }
        return result;

      case AlternationPattern():
        // Compile each alternative and apply its individual precedence level if specified
        Pattern result = _compilePattern(expr.patterns[0], precedenceLevels);
        final level0 = precedenceLevels[expr.patterns[0]];
        if (level0 != null) {
          result = result.atLevel(level0);
        }

        for (int i = 1; i < expr.patterns.length; i++) {
          var altPattern = _compilePattern(expr.patterns[i], precedenceLevels);
          // Apply precedence level to this specific alternative if it has one
          final altLevel = precedenceLevels[expr.patterns[i]];
          if (altLevel != null) {
            altPattern = altPattern.atLevel(altLevel);
          }
          result = result | altPattern;
        }

        return result;

      case ConjunctionPattern():
        Pattern result = _compilePattern(expr.patterns[0], precedenceLevels);
        for (int i = 1; i < expr.patterns.length; i++) {
          result = result & _compilePattern(expr.patterns[i], precedenceLevels);
        }
        return result;

      case RepetitionPattern():
        final pattern = _compilePattern(expr.pattern, precedenceLevels);
        switch (expr.kind) {
          case RepetitionKind.zeroOrMore:
            return pattern.star();
          case RepetitionKind.oneOrMore:
            return pattern.plus();
          case RepetitionKind.optional:
            return pattern | Eps();
        }

      case GroupPattern():
        return _compilePattern(expr.inner, precedenceLevels);

      case ActionExpr():
        throw Exception('ActionExpr cannot be compiled as a pattern');

      case PredicatePattern():
        final inner = _compilePattern(expr.pattern, precedenceLevels);
        if (expr.isAnd) {
          return And(inner);
        } else {
          return Not(inner);
        }
    }
  }
}

extension GrammarFileExtension on String {
  SMParser toSMParser() => SMParser(GrammarFileCompiler(GrammarFileParser(this).parse()).compile());
}
