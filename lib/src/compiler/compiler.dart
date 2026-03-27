/// Compiles a parsed grammar file into an executable Grammar
library glush.grammar_file_compiler;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/parser.dart";
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/sm_parser.dart";

/// Compiles a GrammarFile into an executable Grammar
class GrammarFileCompiler {
  GrammarFileCompiler(this.grammarFile);
  final GrammarFile grammarFile;
  late final Map<String, Rule> _rules = {};
  late final Map<String, RuleDefinition> _definitions = {
    for (var rule in grammarFile.rules) rule.name: rule,
  };
  final Map<IfPattern, Rule> _guardedRules = {};
  Rule? _currentOwnerRule;
  List<String> _currentParameters = const [];

  /// Compile the grammar file into an executable Grammar
  Grammar compile({String? startRuleName}) {
    return GlushProfiler.measure("compiler.grammar_compile", () {
      // First pass: create rule stubs with builder functions
      for (var ruleDef in grammarFile.rules) {
        late Rule rule;
        rule = Rule(ruleDef.name, () {
          var previousOwner = _currentOwnerRule;
          var previousParameters = _currentParameters;
          _currentOwnerRule = rule;
          _currentParameters = ruleDef.parameters;
          try {
            return GlushProfiler.measure("compiler.compile_pattern", () {
              return _compilePattern(ruleDef.pattern, ruleDef.precedenceLevels);
            });
          } finally {
            _currentOwnerRule = previousOwner;
            _currentParameters = previousParameters;
          }
        });
        _rules[ruleDef.name] = rule;
        GlushProfiler.increment("compiler.rules_compiled");
      }

      // Return grammar with the first rule as the start rule
      if (grammarFile.rules.isEmpty) {
        throw Exception("No rules defined in grammar");
      }

      var startRule = _rules[startRuleName ?? grammarFile.rules.first.name]!;
      return Grammar(() => startRule);
    });
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
      // `if (...)` is lowered into a synthetic guarded rule so the compiler
      // keeps the parser logic in the state machine instead of inventing a
      // separate semantic side channel.
      case IfPattern(:var guard, :var inner):
        var owner = _currentOwnerRule;
        var parameters = _currentParameters;
        var guardedRule = _guardedRules[expr];
        if (guardedRule == null) {
          var syntheticName = "_if\$${_guardedRules.length}";
          var rule = Rule(syntheticName, () {
            var previousOwner = _currentOwnerRule;
            var previousParameters = _currentParameters;
            _currentOwnerRule = owner;
            _currentParameters = parameters;
            try {
              return _compilePattern(inner, precedenceLevels);
            } finally {
              _currentOwnerRule = previousOwner;
              _currentParameters = previousParameters;
            }
          });
          rule.guardOwner = owner;
          guardedRule = _guardedRules[expr] = rule;
        }
        guardedRule.guard = GuardExpr.expression(_compileCallArgumentValue(guard));
        if (parameters.isEmpty) {
          return guardedRule();
        }
        return guardedRule.call(
          arguments: {for (var name in parameters) name: CallArgumentValue.reference(name)},
        );

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
        // A bare reference to one of the current rule's parameters must stay as
        // a parameter lookup, not a global rule call, so call-site data can
        // flow into the body without losing its source.
        if (_currentParameters.contains(expr.ruleName)) {
          if (expr.arguments.isNotEmpty) {
            return ParameterCallPattern(
              expr.ruleName,
              arguments: _compileParameterCallArguments(expr),
              minPrecedenceLevel: expr.precedenceConstraint,
            );
          }
          return ParameterRefPattern(expr.ruleName);
        }
        var rule = _rules[expr.ruleName];
        if (rule == null) {
          throw Exception("Undefined rule: ${expr.ruleName}");
        }
        var ruleDef = _definitions[expr.ruleName];
        if (expr.arguments.isNotEmpty && (ruleDef?.parameters.isEmpty ?? true)) {
          Pattern result = rule.call(minPrecedenceLevel: expr.precedenceConstraint);
          for (var argument in expr.arguments) {
            result = result >> _compileFallbackArgumentPattern(argument.value);
          }
          return result;
        }
        return rule.call(
          arguments: _compileCallArguments(expr, ruleDef?.parameters ?? const []),
          minPrecedenceLevel: expr.precedenceConstraint,
        );

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

      case StarBangPattern():
        return Star(_compilePattern(expr.pattern, precedenceLevels)) >>
            Not(_compilePattern(expr.pattern, precedenceLevels));

      case PlusPattern():
        return Plus(_compilePattern(expr.pattern, precedenceLevels));

      case PlusBangPattern():
        return Plus(_compilePattern(expr.pattern, precedenceLevels)) >>
            Not(_compilePattern(expr.pattern, precedenceLevels));

      case GroupPattern():
        return _compilePattern(expr.inner, precedenceLevels);

      case LabeledPattern(:var label, :var inner):
        return Label(label, _compilePattern(inner, precedenceLevels));

      case MainMarkPattern(:var name, :var inner):
        var compiled = _compilePattern(inner, precedenceLevels);
        var ruleName = _currentOwnerRule?.name;
        return Label(ruleName == null ? name : "$ruleName.$name", compiled);

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

  Map<String, CallArgumentValue> _compileCallArguments(
    RuleRefPattern expr,
    List<String> parameters,
  ) {
    if (expr.arguments.isEmpty) {
      return const {};
    }

    if (parameters.isEmpty) {
      throw Exception("Rule ${expr.ruleName} does not declare parameters");
    }

    var compiled = <String, CallArgumentValue>{};
    var positionalIndex = 0;

    for (var argument in expr.arguments) {
      var name = argument.name;
      if (name != null) {
        if (!parameters.contains(name)) {
          throw Exception("Unknown parameter '$name' for rule ${expr.ruleName}");
        }
        // Named arguments are normalized into the callee's declared parameter
        // names so the runtime can resolve them in a stable order.
        compiled[name] = _compileCallArgumentValue(argument.value);
        continue;
      }

      if (positionalIndex >= parameters.length) {
        throw Exception("Too many arguments for rule ${expr.ruleName}");
      }
      compiled[parameters[positionalIndex++]] = _compileCallArgumentValue(argument.value);
    }

    return compiled;
  }

  CallArgumentValue _compileCallArgumentValue(CallArgumentValueNode value) {
    return switch (value) {
      // Literal values remain typed as data here; whether they become parser
      // material or guard data is decided later by the consuming rule.
      GuardBoolLiteralNode(:var value) => CallArgumentValue.literal(value),
      GuardNumberLiteralNode(:var value) => CallArgumentValue.literal(value),
      GuardStringLiteralNode(:var value) => CallArgumentValue.literal(value),
      ExpressionGroupNode(:var inner) => _compileCallArgumentValue(inner),
      ExpressionMemberNode(:var target, :var member) => CallArgumentValue.member(
        _compileCallArgumentValue(target),
        member,
      ),
      ExpressionUnaryNode(:var operator, :var operand) => CallArgumentValue.unary(
        operator,
        _compileCallArgumentValue(operand),
      ),
      ExpressionBinaryNode(:var left, :var operator, :var right) => CallArgumentValue.binary(
        _compileCallArgumentValue(left),
        operator,
        _compileCallArgumentValue(right),
      ),
      // A bare identifier means either "pass this rule object" or "look this
      // name up at runtime", depending on what exists in the rule table.
      GuardNameNode(:var name) =>
        _rules[name] != null
            ? CallArgumentValue.rule(_rules[name]!)
            : CallArgumentValue.reference(name),
      GuardRuleNode() => CallArgumentValue.currentRule(),
      PatternExpr() => CallArgumentValue.pattern(_compilePattern(value, const {})),
    };
  }

  Pattern _compileFallbackArgumentPattern(CallArgumentValueNode value) {
    return switch (value) {
      // This fallback preserves the old "inline parser" behavior for rules
      // that do not declare parameters of their own.
      GuardStringLiteralNode(:var value) => Pattern.string(value),
      GuardNumberLiteralNode(:var value) => Pattern.string(value.toString()),
      GuardBoolLiteralNode(:var value) => Pattern.string(value.toString()),
      ExpressionGroupNode(:var inner) => _compileFallbackArgumentPattern(inner),
      ExpressionMemberNode() => throw Exception(
        "Expression arguments require a parameterized rule",
      ),
      ExpressionUnaryNode() || ExpressionBinaryNode() => throw Exception(
        "Expression arguments require a parameterized rule",
      ),
      GuardNameNode(:var name) => switch (name) {
        "start" => Pattern.start(),
        "eof" => Pattern.eof(),
        _ => _rules[name]?.call() ?? Pattern.string(name),
      },
      GuardRuleNode() => Pattern.string("rule"),
      PatternExpr() => _compilePattern(value, const {}),
    };
  }

  Map<String, CallArgumentValue> _compileParameterCallArguments(RuleRefPattern expr) {
    var compiled = <String, CallArgumentValue>{};
    for (var argument in expr.arguments) {
      var name = argument.name;
      if (name == null) {
        throw Exception(
          "Positional arguments are not supported when invoking a parameter: ${expr.ruleName}",
        );
      }
      compiled[name] = _compileCallArgumentValue(argument.value);
    }
    return compiled;
  }
}

extension GrammarFileExtension on String {
  SMParser toSMParser({String? startRuleName, bool captureTokensAsMarks = false}) => SMParser(
    GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName),
    captureTokensAsMarks: captureTokensAsMarks,
  );
}
