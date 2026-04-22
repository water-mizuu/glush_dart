/// Compiles a parsed grammar file into an executable Grammar
library glush.grammar_file_compiler;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/parser.dart";
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/sm_parser.dart";

/// Transforms a [GrammarFile] AST into an executable [Grammar] object.
///
/// The compiler converts high-level PEG declarations into the operational
/// [Pattern] tree used by the Glushkov state machine. It handles rule stubs,
/// parameter binding, lookahead predicates, and synthetic rule generation for
/// guarded patterns (`if` expressions).
class GrammarFileCompiler {
  /// Creates a compiler for the given [grammarFile].
  GrammarFileCompiler(this.grammarFile);

  /// The source AST to be compiled.
  final GrammarFile grammarFile;

  /// A cache of compiled [Rule] objects indexed by their name.
  late final Map<String, Rule> _rules = {};

  /// A mapping of rule names to their original AST definitions.
  late final Map<String, RuleDefinition> _definitions = {
    for (var rule in grammarFile.rules) rule.name: rule,
  };

  final Map<IfPattern, Rule> _guardedRules = {};
  Rule? _backreferenceRule;
  Rule? _currentOwnerRule;

  List<String> _currentCaptures = const [];
  List<String> _currentParameters = const [];

  /// Orchestrates the compilation of all rules in the grammar file.
  ///
  /// The compilation is performed in two logical passes:
  /// 1. **Stub Generation**: Every rule name is mapped to a [Rule] object with
  ///     a lazy builder function. This allows rules to reference each other
  ///     (including recursion) before their bodies are fully compiled.
  /// 2. **Body Compilation**: When a rule is first accessed (usually during
  ///     state machine construction), its builder function is executed to
  ///     compile its [PatternExpr] body into a [Pattern] tree.
  Grammar compile({String? startRuleName}) {
    return GlushProfiler.measure("compiler.grammar_compile", () {
      // First pass: create rule stubs with builder functions
      for (var ruleDef in grammarFile.rules) {
        late Rule rule;
        rule = Rule(ruleDef.name, () {
          var previousOwner = _currentOwnerRule;
          var previousParameters = _currentParameters;
          var previousCaptures = _currentCaptures;
          _currentOwnerRule = rule;
          _currentParameters = ruleDef.parameters;
          _currentCaptures = [];

          return GlushProfiler.measure("compiler.compile_pattern", () {
            var compiled = _compilePattern(ruleDef.pattern);

            _currentOwnerRule = previousOwner;
            _currentParameters = previousParameters;
            _currentCaptures = previousCaptures;

            return compiled;
          });
        });
        _rules[ruleDef.name] = rule;
        GlushProfiler.increment("compiler.rules_compiled");
      }

      // Return grammar with the first rule as the start rule
      if (grammarFile.rules.isEmpty) {
        throw Exception("No rules defined in grammar");
      }

      var startRule = _rules[startRuleName ?? grammarFile.rules.first.name];
      if (startRule == null) {
        throw StateError(
          "Rule name '$startRuleName' was given, "
          "but did not exist in the grammar.",
        );
      }

      return Grammar(() => startRule);
    });
  }

  Pattern _token(CharRange range) {
    if (range.startCode == range.endCode) {
      return Token(ExactToken(range.startCode));
    }

    return Token(RangeToken(range.startCode, range.endCode));
  }

  /// Recursively transforms a [PatternExpr] AST node into a [Pattern].
  ///
  /// This method performs the heavy lifting of lowering high-level grammar
  /// features into the core parsing primitives. Key transformations include:
  /// - **Guarded Rules**: Lowering `if (condition)` into synthetic rules with
  ///   semantic guards.
  /// - **Rule Calls**: Resolving references to other rules, parameters, or
  ///   backreferences.
  /// - **Literals and Ranges**: Converting strings and character classes into
  ///   token patterns.
  /// - **Captures**: Tracking and establishing [Label] boundaries for groups.
  Pattern _compilePattern(PatternExpr expr) {
    switch (expr) {
      case PrecedenceExpr(:var level, :var pattern):
        return _compilePattern(pattern).atLevel(level);
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
              return _compilePattern(inner);
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
        return Token.any();

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

      case RetreatPattern():
        return Retreat();

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

        /// We check the existing rules first.
        ///   This allows us to use captures AND rules like:
        ///   ```
        ///   entry = name:name ':' value:name
        ///   name = [A-Z]+
        ///   ```
        ///   without it being rewritten as the backreference pattern.
        var rule = _rules[expr.ruleName];
        if (rule != null) {
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
        }

        // If we found it on the capture list:
        if (_currentCaptures.contains(expr.ruleName)) {
          /// S = s:'s' s
          ///
          /// is rewritten as
          ///
          /// S = s:'s' m'(s)
          /// m'($) = $
          _backreferenceRule ??= Rule("'back0", () => ParameterRefPattern(r"$"));

          return _backreferenceRule!.call(
            arguments: {r"$": CallArgumentValue.reference(expr.ruleName)},
          );
        }

        if (expr.ruleName == "start" && expr.arguments.isEmpty) {
          return Pattern.start();
        }
        if (expr.ruleName == "eof" && expr.arguments.isEmpty) {
          return Pattern.eof();
        }

        throw Exception("Undefined rule: ${expr.ruleName}");

      case SequencePattern():
        Pattern result = _compilePattern(expr.patterns[0]);
        for (int i = 1; i < expr.patterns.length; i++) {
          result = result >> _compilePattern(expr.patterns[i]);

          /// Shortcut for reducing !A . --> ~A.
          if (result case Seq(
            left: Not(pattern: Token tok),
            right: Token(choice: RangeToken(start: 0, end: 255) || AnyToken()),
          )) {
            return Token(NotToken(tok.choice));
          }
        }
        return result;

      case AlternationPattern():
        var beforeCaptures = _currentCaptures;

        Pattern result = _compilePattern(expr.patterns[0]);
        _currentCaptures = beforeCaptures;

        for (int i = 1; i < expr.patterns.length; i++) {
          var altPattern = _compilePattern(expr.patterns[i]);
          _currentCaptures = beforeCaptures;
          result = result | altPattern;
        }

        return result;

      case ConjunctionPattern():
        Pattern result = _compilePattern(expr.patterns[0]);
        for (int i = 1; i < expr.patterns.length; i++) {
          result = result & _compilePattern(expr.patterns[i]);
        }
        return result;

      case RepetitionPattern():
        var pattern = _compilePattern(expr.pattern);
        switch (expr.kind) {
          case RepetitionKind.zeroOrMore:
            return pattern.star();
          case RepetitionKind.oneOrMore:
            return pattern.plus();
          case RepetitionKind.optional:
            return pattern.opt();
        }

      case StarPattern():
        return Star(_compilePattern(expr.pattern));

      case StarBangPattern():
        return Star(_compilePattern(expr.pattern)) >> Not(_compilePattern(expr.pattern));

      case PlusPattern():
        return Plus(_compilePattern(expr.pattern));

      case PlusBangPattern():
        return Plus(_compilePattern(expr.pattern)) >> Not(_compilePattern(expr.pattern));

      case GroupPattern():
        return _compilePattern(expr.inner);

      case LabeledPattern(:var label, :var inner):
        var innerPattern = _compilePattern(inner);
        if (innerPattern is And || innerPattern is Not) {
          return innerPattern;
        }

        var result = Label(label, innerPattern);
        _currentCaptures = [..._currentCaptures, label];

        return result;

      case MainMarkPattern(:var name, :var inner):
        var compiled = _compilePattern(inner);
        var ruleName = _currentOwnerRule?.name;
        return Label(ruleName == null ? name : "$ruleName.$name", compiled);

      case ActionExpr():
        throw Exception("ActionExpr cannot be compiled as a pattern");

      case PredicatePattern():
        var inner = _compilePattern(expr.pattern);
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

  /// Resolves arguments for a rule call and binds them to parameter names.
  ///
  /// This method ensures that positional and named arguments provided in the
  /// [RuleRefPattern] match the [parameters] expected by the target rule. It
  /// produces a stable mapping of names to [CallArgumentValue] objects.
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
        _currentParameters.contains(name)
            ? CallArgumentValue.reference(name)
            : _rules[name] != null
            ? CallArgumentValue.rule(_rules[name]!)
            : switch (name) {
                "rule" => CallArgumentValue.currentRule(),
                "start" => CallArgumentValue.pattern(Pattern.start()),
                "eof" => CallArgumentValue.pattern(Pattern.eof()),
                _ => CallArgumentValue.reference(name),
              },
      PatternExpr() => CallArgumentValue.pattern(_compilePattern(value)),
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
      GuardNameNode(:var name) =>
        _currentParameters.contains(name)
            ? ParameterRefPattern(name)
            : _rules[name] != null
            ? _rules[name]!.call()
            : switch (name) {
                "start" => Pattern.start(),
                "eof" => Pattern.eof(),
                _ => Pattern.string(name),
              },
      PatternExpr() => _compilePattern(value),
    };
  }

  /// Resolves named arguments for a call to a dynamic parameter.
  ///
  /// When a parameter itself is invoked (e.g., `$p(arg: val)`), positional
  /// arguments are disallowed because the target's parameter list is unknown
  /// at compile time.
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
  Grammar toGrammar({String? startRuleName}) =>
      GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName);

  SMParser toSMParser({String? startRuleName}) => SMParser(
    GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName),
  );
}
