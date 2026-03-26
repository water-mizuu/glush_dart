/// Compiles a parsed grammar file into an executable Grammar
library glush.grammar_file_compiler;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/parser.dart";
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/parser/sm_parser.dart";

/// Compiles a GrammarFile into an executable Grammar
class GrammarFileCompiler {
  GrammarFileCompiler(this.grammarFile);
  final GrammarFile grammarFile;
  late final Map<String, Rule> _rules = {};

  /// Compile the grammar file into an executable Grammar
  Grammar compile({String? startRuleName}) {
    // First pass: create rule stubs with builder functions
    for (var ruleDef in grammarFile.rules) {
      var rule = Rule(ruleDef.name, () {
        return _compilePattern(ruleDef.pattern, ruleDef.precedenceLevels);
      });
      _rules[ruleDef.name] = rule;
    }

    // Return grammar with the first rule as the start rule
    if (grammarFile.rules.isEmpty) {
      throw Exception("No rules defined in grammar");
    }

    var startRule = _rules[startRuleName ?? grammarFile.rules.first.name]!;
    return Grammar(() => startRule);
  }

  Pattern _token(CharRange range) {
    if (range.startCode == range.endCode) {
      return Token(ExactToken(range.startCode));
    }

    return Token(RangeToken(range.startCode, range.endCode));
  }

  /// Compile a pattern expression into a Pattern
  Pattern _compilePattern(PatternExpr expr, Map<PatternExpr, int> precedenceLevels) {
    switch (expr) {
      case AnyPattern():
        return Token(const AnyToken());

      case StartPattern():
        return Pattern.start();

      case EofPattern():
        return Pattern.eof();

      case LiteralPattern(:var literal):
        return Pattern.string(literal);

      case CharRangePattern(:var ranges):
        if (ranges.length == 1) {
          var range = ranges[0];
          return Token(RangeToken(range.startCode, range.endCode));
        }
        // Multiple ranges: use alternation
        Pattern result = _token(ranges[0]);
        for (int i = 1; i < ranges.length; i++) {
          result = result | _token(ranges[i]);
        }
        return result;
      case LessThanPattern(:var codePoint):
        return Token(LessToken(codePoint));

      case GreaterThanPattern(:var codePoint):
        return Token(GreaterToken(codePoint));

      case MarkerPattern(:var name):
        return Marker(name);

      case RuleRefPattern():
        var rule = _rules[expr.ruleName];
        if (rule == null) {
          throw Exception("Undefined rule: ${expr.ruleName}");
        }
        return rule(minPrecedenceLevel: expr.precedenceConstraint);

      case SequencePattern():
        Pattern result = _compilePattern(expr.patterns[0], precedenceLevels);
        for (int i = 1; i < expr.patterns.length; i++) {
          result = result >> _compilePattern(expr.patterns[i], precedenceLevels);
        }
        return result;

      case AlternationPattern():
        // Compile each alternative and apply its individual precedence level if specified
        Pattern result = _compilePattern(expr.patterns[0], precedenceLevels);
        var level0 = precedenceLevels[expr.patterns[0]];
        if (level0 != null) {
          result = result.atLevel(level0);
        }

        for (int i = 1; i < expr.patterns.length; i++) {
          var altPattern = _compilePattern(expr.patterns[i], precedenceLevels);
          // Apply precedence level to this specific alternative if it has one
          var altLevel = precedenceLevels[expr.patterns[i]];
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
        var pattern = _compilePattern(expr.pattern, precedenceLevels);
        switch (expr.kind) {
          case RepetitionKind.zeroOrMore:
            return pattern.star();
          case RepetitionKind.oneOrMore:
            return pattern.plus();
          case RepetitionKind.optional:
            return pattern.opt();
        }

      case StarPattern():
        return Star(_compilePattern(expr.pattern, precedenceLevels));

      case PlusPattern():
        return Plus(_compilePattern(expr.pattern, precedenceLevels));

      case GroupPattern():
        return _compilePattern(expr.inner, precedenceLevels);

      case LabeledPattern(:var label, :var inner):
        return Label(label, _compilePattern(inner, precedenceLevels));

      case ActionExpr():
        throw Exception("ActionExpr cannot be compiled as a pattern");

      case PredicatePattern():
        var inner = _compilePattern(expr.pattern, precedenceLevels);
        if (expr.isAnd) {
          return And(inner);
        } else {
          return Not(inner);
        }

      case BackslashLiteralPattern(:var char):
        return switch (char) {
          "n" => Token(const ExactToken(10)),
          "r" => Token(const ExactToken(13)),
          "t" => Token(const ExactToken(9)),
          "d" => Token(const RangeToken(48, 57)),
          "D" => Token(const RangeToken(48, 57)).invert(),
          "w" =>
            Token(const RangeToken(65, 90)) |
                Token(const RangeToken(97, 122)) |
                Token(const RangeToken(48, 57)) |
                Token(const ExactToken(95)),
          "W" =>
            (Token(const RangeToken(65, 90)) |
                    Token(const RangeToken(97, 122)) |
                    Token(const RangeToken(48, 57)) |
                    Token(const ExactToken(95)))
                .invert(),
          "s" =>
            Token(const ExactToken(32)) | // space
                Token(const ExactToken(9)) | // tab
                Token(const ExactToken(10)) | // nl
                Token(const ExactToken(13)) | // cr
                Token(const ExactToken(12)) | // ff
                Token(const ExactToken(11)), // vt
          "S" =>
            (Token(const ExactToken(32)) |
                    Token(const ExactToken(9)) |
                    Token(const ExactToken(10)) |
                    Token(const ExactToken(13)) |
                    Token(const ExactToken(12)) |
                    Token(const ExactToken(11)))
                .invert(),
          _ => throw Exception("Unsupported backslash literal: \\$char"),
        };
    }
  }
}

extension GrammarFileExtension on String {
  SMParser toSMParser({String? startRuleName, bool captureTokensAsMarks = false}) => SMParser(
    GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName),
    captureTokensAsMarks: captureTokensAsMarks,
  );
}
