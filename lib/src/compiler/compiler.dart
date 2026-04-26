/// Compiles a parsed grammar file into an executable Grammar
library glush.grammar_file_compiler;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/compiler/parser.dart";
import "package:glush/src/core/grammar.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/helper/range.dart";
import "package:glush/src/parser/sm_parser.dart";

const int _asciiTab = 0x09;
const int _asciiLineFeed = 0x0A;
const int _asciiVerticalTab = 0x0B;
const int _asciiFormFeed = 0x0C;
const int _asciiCarriageReturn = 0x0D;
const int _asciiSpace = 0x20;
const int _asciiDigit0 = 0x30;
const int _asciiDigit9 = 0x39;
const int _asciiUpperA = 0x41;
const int _asciiUpperZ = 0x5A;
const int _asciiUnderscore = 0x5F;
const int _asciiLowerA = 0x61;
const int _asciiLowerZ = 0x7A;

const _lowercase = IntegerRange.unit(_asciiLowerA, _asciiLowerZ + 1);
const _uppercase = IntegerRange.unit(_asciiUpperA, _asciiUpperZ + 1);
const _digit = IntegerRange.unit(_asciiDigit0, _asciiDigit9 + 1);
final _word = _uppercase | _lowercase | _digit | const IntegerRange.single(_asciiUnderscore);
final _space =
    const IntegerRange.single(_asciiTab) |
    const IntegerRange.single(_asciiLineFeed) |
    const IntegerRange.single(_asciiVerticalTab) |
    const IntegerRange.single(_asciiFormFeed) |
    const IntegerRange.single(_asciiCarriageReturn) |
    const IntegerRange.single(_asciiSpace);

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

  Rule? _currentOwnerRule;

  List<String> _currentCaptures = const [];

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
          var previousCaptures = _currentCaptures;
          _currentOwnerRule = rule;
          _currentCaptures = [];

          return GlushProfiler.measure("compiler.compile_pattern", () {
            var compiled = _compilePattern(ruleDef.pattern);

            _currentOwnerRule = previousOwner;
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
  /// - **Rule Calls**: Resolving references to other rules, parameters, or
  ///   backreferences.
  /// - **Literals and Ranges**: Converting strings and character classes into
  ///   token patterns.
  /// - **Captures**: Tracking and establishing [Label] boundaries for groups.
  Pattern _compilePattern(PatternExpr expr) {
    switch (expr) {
      case PrecedenceExpr(:var level, :var pattern):
        return _compilePattern(pattern).atLevel(level);
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

      case RuleRefPattern():

        /// We check the existing rules first.
        ///   This allows us to use captures AND rules like:
        ///   ```
        ///   entry = name:name ':' value:name
        ///   name = [A-Z]+
        ///   ```
        ///   without it being rewritten as the backreference pattern.
        var rule = _rules[expr.ruleName];
        if (rule != null) {
          return rule.call(minPrecedenceLevel: expr.precedenceConstraint);
        }

        if (expr.ruleName == "start") {
          return Pattern.start();
        }
        if (expr.ruleName == "eof") {
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

      case PredicatePattern():
        var inner = _compilePattern(expr.pattern);
        if (expr.isAnd) {
          return And(inner);
        } else {
          return Not(inner);
        }

      case BackslashLiteralPattern(:var char):
        return switch (char) {
          "n" => Token(const ExactToken(_asciiLineFeed)),
          "r" => Token(const ExactToken(_asciiCarriageReturn)),
          "t" => Token(const ExactToken(_asciiTab)),
          "d" => Token(const ComplexToken(_digit)),
          "D" => Token(const NotToken(ComplexToken(_digit))),
          "w" => Token(ComplexToken(_word)),
          "W" => Token(NotToken(ComplexToken(_word))),
          "s" => Token(ComplexToken(_space)), // vt
          "S" => Token(NotToken(ComplexToken(_space))),
          _ => throw Exception("Unsupported backslash literal: \\$char"),
        };
    }
  }
}

extension GrammarFileExtension on String {
  Grammar toGrammar({String? startRuleName}) =>
      GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName);

  SMParser toSMParser({String? startRuleName}) => SMParser(
    GrammarFileCompiler(GrammarFileParser(this).parse()).compile(startRuleName: startRuleName),
  );
}
