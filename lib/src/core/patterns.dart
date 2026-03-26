/// Pattern system for grammar definition
library glush.patterns;

import "package:glush/src/core/errors.dart";

extension type const PatternSymbol(String symbol) {}

sealed class Pattern {
  Pattern();

  factory Pattern.char(String char) = Token.char;
  factory Pattern.start() = StartAnchor;
  factory Pattern.eof() = EofAnchor;
  factory Pattern.any() = Token.any;
  factory Pattern.string(String pattern) {
    if (pattern.isEmpty) {
      return Eps();
    }

    if (pattern.codeUnits.length == 1) {
      return Token(ExactToken(pattern.codeUnits.single));
    }

    List<int> codeUnits = pattern.codeUnits;
    Pattern result = codeUnits
        .map((u) => Token(ExactToken(u)))
        .cast<Pattern>()
        .reduce((acc, curr) => acc >> curr)
        .withAction((span, _) => span);

    return result;
  }

  /// Symbol ID assigned by the grammar this pattern belongs to.
  /// Initially null, assigned during Grammar.finalize()
  PatternSymbol? _symbolId;

  PatternSymbol? get symbolId =>
      (_symbolId == null) //
      ? null
      : PatternSymbol("$_symbolPrefix:$_symbolId:$_symbolSuffix");

  set symbolId(PatternSymbol id) {
    if ((id as String).split(":") case [_, var mid, _]) {
      _symbolId = PatternSymbol(mid);
      return;
    }
    _symbolId = id;
  }

  bool? _isEmptyComputed;
  bool? _isEmpty;
  bool _consumed = false;

  /// Copy this pattern, resetting consumption state
  Pattern copy();

  /// Mark this pattern as consumed
  Pattern consume() {
    if (_consumed) {
      return copy().consume();
    }
    _consumed = true;
    return this;
  }

  /// Check if this pattern can match empty input
  bool empty() {
    if (_isEmptyComputed != null) {
      return _isEmpty ?? false;
    }
    throw StateError("empty is not computed for $runtimeType");
  }

  /// Set the empty flag (computed by grammar)
  // ignore: avoid_positional_boolean_parameters
  void setEmpty(bool value) {
    _isEmpty = value;
    _isEmptyComputed = true;
  }

  /// Check if this pattern is a single token
  bool singleToken() => false;

  /// Check if the pattern matches a token
  bool match(int? token) {
    throw UnimplementedError("match not implemented for $runtimeType");
  }

  /// Invert this pattern  (matches everything except this)
  Pattern invert() {
    throw UnimplementedError("invert not implemented for $runtimeType");
  }

  /// Calculate if pattern is empty
  bool calculateEmpty(Set<Rule> emptyRules) {
    throw UnimplementedError("calculateEmpty not implemented for $runtimeType");
  }

  /// Check if pattern is "static" (can appear in empty position)
  bool isStatic() {
    throw UnimplementedError("isStatic not implemented for $runtimeType");
  }

  /// Get first set (patterns at the beginning)
  Set<Pattern> firstSet() {
    throw UnimplementedError("firstSet not implemented for $runtimeType");
  }

  /// Get last set (patterns at the end)
  Set<Pattern> lastSet() {
    throw UnimplementedError("lastSet not implemented for $runtimeType");
  }

  /// Iterate over (a, b) pairs where a is connected to b
  void eachPair(void Function(Pattern, Pattern) callback) {}

  /// Collect all Rule instances referenced in this pattern
  void collectRules(Set<Rule> rules) {}

  /// Operator overloads for DSL
  Seq operator >>(Pattern other) => Seq(this, other);
  Alt operator |(Pattern other) => Alt(this, other);
  Conj operator &(Pattern other) => Conj(this, other);

  /// Attach a semantic action to this pattern.
  /// The callback receives (span, childResults) where:
  ///   - span: the matched substring
  ///   - childResults: list of evaluated semantic values from children
  Action<T> withAction<T>(T Function(String span, List<dynamic> childResults) callback) {
    return Action<T>(this, callback);
  }

  /// Repetition operators
  // ignore: use_to_and_as_if_applicable
  Pattern plus() => Plus(this);
  // ignore: use_to_and_as_if_applicable
  Pattern star() => Star(this);
  // ignore: use_to_and_as_if_applicable
  Pattern opt() => Opt(this);

  /// This discriminates the type of the pattern from the symbol
  ///   without making an entire rule object.
  String get _symbolPrefix {
    return switch (this) {
      Token() => "tok",
      Marker() => "mar",
      StartAnchor() => "bos",
      EofAnchor() => "eof",
      Eps() => "eps",
      Alt() => "alt",
      Seq() => "seq",
      Conj() => "con",
      And() => "and",
      Not() => "not",
      Neg() => "neg",
      Rule() => "rul",
      RuleCall() => "rca",
      Action() => "act",
      Prec() => "pre",
      Opt() => "opt",
      Plus() => "plu",
      Star() => "sta",
      Label() => "lab",
      LabelStart() => "las",
      LabelEnd() => "lae",
    };
  }

  String get _symbolSuffix {
    return switch (this) {
      Token(:var choice) => switch (choice) {
        AnyToken() => ".any",
        ExactToken(:var value) => ";$value",
        RangeToken(:var start, :var end) => "[$start,$end",
        LessToken(:var bound) => "<$bound",
        GreaterToken(:var bound) => ">$bound",
      },
      Marker(:var name) => name,
      StartAnchor() => "",
      EofAnchor() => "",
      Eps() => "",
      Alt() => "",
      Seq() => "",
      Conj() => "",
      And() => "",
      Not() => "",
      Neg() => "",
      Rule() => "",
      RuleCall(minPrecedenceLevel: var prec) => prec == null ? "" : "$prec",
      Action() => "",
      Prec(precedenceLevel: var prec) => "$prec",
      Opt() => "",
      Plus() => "",
      Star() => "",
      Label(:var name) => name,
      LabelStart(:var name) => name,
      LabelEnd(:var name) => name,
    };
  }

  Alt maybe() => this | Eps();

  /// Positive lookahead predicate (AND) - succeeds if pattern matches at current position
  /// without consuming input. Allows lookahead without consumption.
  /// Example: &token('a') >> token('a') matches 'a' only when 'a' is present
  // ignore: use_to_and_as_if_applicable
  And and() => And(this);

  /// Negative lookahead predicate (NOT) - succeeds if pattern does NOT match at current position
  /// without consuming input. Prevents matching when pattern would succeed.
  /// Example: !token('x') >> token('a') matches 'a' only when NOT 'x'
  // ignore: use_to_and_as_if_applicable
  Not not() => Not(this);

  /// Span-level negation (NEG) - matches if pattern does NOT match the EXACT span (i,j).
  /// Consumes input.
  /// Example: ident & neg(keyword) matches an identifier that is not a keyword.
  // ignore: use_to_and_as_if_applicable
  Neg neg() => Neg(this);
}

/// Sealed class hierarchy for token choice — replaces the former dynamic field.
sealed class TokenChoice {
  const TokenChoice();
  bool matches(int? value);
}

/// Matches any token (wildcard)
final class AnyToken extends TokenChoice {
  const AnyToken();

  @override
  bool matches(int? value) => value != null;

  @override
  String toString() => "any";
}

/// Matches an exact code-point value
final class ExactToken extends TokenChoice {
  const ExactToken(this.value);
  final int value;

  @override
  bool matches(int? token) => token == value;

  @override
  String toString() => String.fromCharCode(value);
}

/// Matches a code-point within an inclusive range
final class RangeToken extends TokenChoice {
  const RangeToken(this.start, this.end);
  final int start;
  final int end;

  @override
  bool matches(int? token) => token != null && token >= start && token <= end;

  @override
  String toString() => "$start..$end";
}

/// Matches a code-point <= bound
final class LessToken extends TokenChoice {
  const LessToken(this.bound);
  final int bound;

  @override
  bool matches(int? token) => token != null && token <= bound;

  @override
  String toString() => "less($bound)";
}

/// Matches a code-point >= bound
final class GreaterToken extends TokenChoice {
  const GreaterToken(this.bound);
  final int bound;

  @override
  bool matches(int? token) => token != null && token >= bound;

  @override
  String toString() => "greater($bound)";
}

/// Single token pattern
class Token extends Pattern {
  Token(this.choice);
  Token.char(String char) //
    : assert(char.length == 1, "Character patterns should have only one value!"),
      assert(
        char.length == char.codeUnits.length,
        "Unicode characters cannot be used in character patterns!",
      ),
      choice = ExactToken(char.codeUnits.single);
  Token.charRange(String from, String to)
    : choice = RangeToken(from.codeUnits.first, to.codeUnits.first);
  Token.any() : choice = const AnyToken();
  final TokenChoice choice;

  @override
  bool singleToken() => true;

  @override
  bool match(int? token) => choice.matches(token);

  @override
  Pattern invert() {
    switch (choice) {
      case ExactToken(:var value):
        return Token(LessToken(value - 1)) | Token(GreaterToken(value + 1));
      case RangeToken(:var start, :var end):
        return Token(LessToken(start - 1)) | Token(GreaterToken(end + 1));
      case LessToken(:var bound):
        return Token(GreaterToken(bound + 1));
      case GreaterToken(:var bound):
        return Token(LessToken(bound - 1));
      default:
        throw Exception("Cannot invert $choice");
    }
  }

  @override
  Token copy() => Token(choice);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => empty();

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => choice.toString();
}

/// Marker for parse tracking
class Marker extends Pattern {
  Marker(this.name);
  final String name;

  @override
  Marker copy() => Marker(name);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => "mark($name)";
}

/// Epsilon (empty pattern)
class Eps extends Pattern {
  static const Set<Pattern> _emptySet = <Pattern>{};

  @override
  Eps consume() => this;

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(true);
    return true;
  }

  @override
  bool isStatic() => false;

  @override
  Set<Pattern> firstSet() => _emptySet;

  @override
  Set<Pattern> lastSet() => _emptySet;

  @override
  Eps copy() => Eps();

  @override
  String toString() => "eps";
}

/// Beginning-of-stream anchor.
///
/// Matches only at absolute input position 0 and consumes no input.
final class StartAnchor extends Pattern {
  @override
  StartAnchor copy() => StartAnchor();

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => "^";
}

/// End-of-stream anchor.
///
/// Matches only at the final zero-width step after the last token.
final class EofAnchor extends Pattern {
  @override
  EofAnchor copy() => EofAnchor();

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => r"$";
}

/// Alternation (choice between patterns)
class Alt extends Pattern {
  Alt(Pattern left, Pattern right) : left = left.consume(), right = right.consume();
  Pattern left;
  Pattern right;

  @override
  Alt copy() => Alt(left, right);

  @override
  bool singleToken() => left.singleToken() && right.singleToken();

  @override
  bool match(int? token) => left.match(token) || right.match(token);

  @override
  Pattern invert() {
    try {
      return left.invert() & right.invert();
    } on GrammarError catch (e) {
      print(e);
      return not();
    }
  }

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var leftEmpty = left.calculateEmpty(emptyRules);
    var rightEmpty = right.calculateEmpty(emptyRules);
    var result = leftEmpty || rightEmpty;
    setEmpty(result);
    return result;
  }

  @override
  bool isStatic() => left.isStatic() || right.isStatic();

  @override
  Set<Pattern> firstSet() => {...left.firstSet(), ...right.firstSet()};
  @override
  Set<Pattern> lastSet() => {...left.lastSet(), ...right.lastSet()};

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    left.eachPair(callback);
    right.eachPair(callback);
  }

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  String toString() => "alt($left, $right)";
}

/// Sequence (patterns in order)
class Seq extends Pattern {
  Seq(Pattern left, Pattern right) : left = left.consume(), right = right.consume();
  Pattern left;
  Pattern right;

  @override
  Seq copy() => Seq(left, right);

  @override
  Pattern invert() => not();

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var leftEmpty = left.calculateEmpty(emptyRules);
    var rightEmpty = right.calculateEmpty(emptyRules);
    var result = leftEmpty && rightEmpty;
    setEmpty(result);
    return result;
  }

  @override
  bool isStatic() => left.isStatic() && right.isStatic();

  @override
  Set<Pattern> firstSet() {
    var leftFirst = left.firstSet();
    if (left.empty()) {
      return {...leftFirst, ...right.firstSet()};
    }
    return leftFirst;
  }

  @override
  Set<Pattern> lastSet() {
    var rightLast = right.lastSet();
    if (right.empty()) {
      return {...left.lastSet(), ...rightLast};
    }
    return rightLast;
  }

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    left.eachPair(callback);
    right.eachPair(callback);

    for (var a in left.lastSet()) {
      for (var b in right.firstSet()) {
        callback(a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  String toString() => "seq($left, $right)";
}

/// Optional pattern (zero-or-one) with ordered-choice semantics.
/// This is modeled as a first-class node instead of rewriting to Alt(child, Eps).
class Opt extends Pattern {
  Opt(Pattern child) : child = child.consume();
  Pattern child;

  @override
  Opt copy() => Opt(child);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    child.calculateEmpty(emptyRules);
    setEmpty(true);
    return true;
  }

  @override
  bool isStatic() => child.isStatic();

  @override
  Set<Pattern> firstSet() => child.firstSet();

  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => "opt($child)";
}

/// Zero-or-more repetition
class Star extends Pattern {
  Star(Pattern child) : child = child.consume();
  Pattern child;

  @override
  Star copy() => Star(child);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    child.calculateEmpty(emptyRules);
    setEmpty(true);
    return true;
  }

  @override
  bool isStatic() => child.isStatic();

  @override
  Set<Pattern> firstSet() => child.firstSet();

  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);

    // Prefer staying in the repetition before exiting in non-ambiguity mode.
    for (var a in child.lastSet()) {
      for (var b in child.firstSet()) {
        callback(a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => "star($child)";
}

/// One-or-more repetition
class Plus extends Pattern {
  Plus(Pattern child) : child = child.consume();
  Pattern child;

  @override
  Plus copy() => Plus(child);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var childEmpty = child.calculateEmpty(emptyRules);
    setEmpty(childEmpty);
    return childEmpty;
  }

  @override
  bool isStatic() => child.isStatic();

  @override
  Set<Pattern> firstSet() => child.firstSet();

  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);

    // Prefer staying in the repetition before exiting in non-ambiguity mode.
    for (var a in child.lastSet()) {
      for (var b in child.firstSet()) {
        callback(a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => "plus($child)";
}

/// Conjunction (both patterns must match)
class Conj extends Pattern {
  Conj(Pattern left, Pattern right) : left = left.consume(), right = right.consume();

  Pattern left;
  Pattern right;

  @override
  bool singleToken() => left.singleToken() && right.singleToken();

  @override
  bool match(int? token) => left.match(token) && right.match(token);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var leftEmpty = left.calculateEmpty(emptyRules);
    var rightEmpty = right.calculateEmpty(emptyRules);
    var result = leftEmpty && rightEmpty;
    setEmpty(result);
    return result;
  }

  @override
  bool isStatic() => left.isStatic() && right.isStatic();

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  Conj copy() => Conj(left, right);

  @override
  Pattern invert() => left.invert() | right.invert();

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  String toString() => "conj($left, $right)";
}

/// Positive lookahead predicate (AND) - matches if pattern succeeds without consuming
/// Example: &('a' >> 'b') >> 'a' will only match 'a' if followed by 'b'
class And extends Pattern {
  And(Pattern p) : pattern = p.consume();
  Pattern pattern;

  @override
  And copy() => And(pattern);

  @override
  Pattern invert() => Not(pattern);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    pattern.calculateEmpty(emptyRules);
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};
  @override
  Set<Pattern> lastSet() => {this};

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    // Predicates don't participate in normal eachPair flow
    // They're checked independently
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  String toString() => "and($pattern)";
}

/// Negative lookahead predicate (NOT) - matches if pattern fails without consuming
/// Example: !('a' >> 'b') >> 'a' will only match 'a' if NOT followed by 'b'
class Not extends Pattern {
  Not(Pattern p) : pattern = p.consume();
  Pattern pattern;

  @override
  Not copy() => Not(pattern);

  @override
  Pattern invert() => And(pattern);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    pattern.calculateEmpty(emptyRules);
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};
  @override
  Set<Pattern> lastSet() => {this};

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    // Predicates don't participate in normal eachPair flow
    // They're checked independently
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  String toString() => "not($pattern)";
}

/// Span-level negation (NEG) - matches if pattern does NOT match the EXACT span (i,j).
class Neg extends Pattern {
  Neg(Pattern p) : pattern = p.consume();
  Pattern pattern;

  @override
  Neg copy() => Neg(pattern);

  @override
  Pattern invert() => pattern; // This is a simplification; ¬(¬A) = A

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    pattern.calculateEmpty(emptyRules);
    // Negation is not zero-width, so it's only empty if it can match empty span
    // But wait, ¬epsilon matches any non-empty span.
    // If A matches empty, ¬A does not match empty.
    // If A doesn't match empty, ¬A matches empty?
    // Actually, ¬A is span-consuming, so it matches any span (i,j) that A doesn't.
    // So yes, it can be empty if A doesn't match (i,i).
    setEmpty(!pattern.empty());
    return empty();
  }

  @override
  bool isStatic() => false;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    // Negations are handled by the state machine as a single unit or conjunction
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  String toString() => "neg($pattern)";
}

extension type RuleName(String symbol) {}

/// Grammar rule
class Rule extends Pattern {
  Rule(String name, this._code) : name = RuleName(name);

  final RuleName name;
  final Pattern Function() _code;
  final List<RuleCall> calls = [];

  Pattern? _body;
  Pattern? guard;

  RuleCall call({int? minPrecedenceLevel}) {
    var name = "${this.name}_${calls.length}";
    var call = RuleCall(name, this, minPrecedenceLevel: minPrecedenceLevel);
    calls.add(call);
    return call;
  }

  Pattern body() {
    _body ??= _code().consume();
    return _body!;
  }

  // ignore: use_setters_to_change_properties
  void setBody(Pattern body) {
    _body = body;
  }

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(body().calculateEmpty(emptyRules));
    return _isEmpty ?? false;
  }

  @override
  Rule copy() => Rule(name.symbol, _code);

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  bool isStatic() => false;

  @override
  void collectRules(Set<Rule> rules) {
    if (rules.contains(this)) {
      return;
    }
    rules.add(this);
    body().collectRules(rules);
  }

  @override
  String toString() => "<$name>";
}

/// Call to a rule with optional precedence constraint
class RuleCall extends Pattern {
  RuleCall(this.name, this.rule, {this.minPrecedenceLevel});
  final String name;
  final Rule rule;

  /// Minimum precedence level filter. If set, only alternatives in the rule
  /// with precedenceLevel >= minPrecedenceLevel will match.
  /// This implements EXPR^N syntax where N is the minimum precedence level.
  final int? minPrecedenceLevel;

  @override
  RuleCall copy() => RuleCall(name, rule, minPrecedenceLevel: minPrecedenceLevel);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(emptyRules.contains(rule));
    return _isEmpty ?? false;
  }

  @override
  Set<Pattern> firstSet() => {this};
  @override
  Set<Pattern> lastSet() => {this};

  @override
  bool isStatic() => false;

  @override
  void collectRules(Set<Rule> rules) {
    rules.add(rule);
    // Don't call rule.body() here to avoid circular initialization issues
  }

  @override
  String toString() => minPrecedenceLevel != null ? "<$name^$minPrecedenceLevel>" : "<$name>";
}

/// Semantic action pattern - executes a callback when child pattern matches.
/// The callback receives (span, childResults) where childResults are the evaluated semantic values.
class Action<T> extends Pattern {
  Action(this.child, this.callback);
  Pattern child;
  final T Function(String span, List<dynamic> childResults) callback;

  @override
  Action<T> copy() => Action<T>(child.copy(), callback);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var childEmpty = child.calculateEmpty(emptyRules);
    setEmpty(childEmpty);
    return childEmpty;
  }

  @override
  bool isStatic() => child.isStatic();

  @override
  Set<Pattern> firstSet() => child.firstSet();
  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  bool singleToken() => child.singleToken();

  @override
  bool match(int? token) => child.match(token);

  @override
  String toString() => "action($child)";
}

/// Pattern labeled with a precedence level for operator precedence parsing.
/// When this pattern is part of a rule body alternation, the precedence level
/// determines which alternatives can match based on precedence constraints.
/// Example: In "6| $add EXPR^6 ... EXPR^7", the entire sequence gets precedenceLevel=6
class Prec extends Pattern {
  Prec(this.precedenceLevel, this.child);
  final int precedenceLevel;
  Pattern child;

  @override
  Prec copy() => Prec(precedenceLevel, child.copy());

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var childEmpty = child.calculateEmpty(emptyRules);
    setEmpty(childEmpty);
    return childEmpty;
  }

  @override
  bool isStatic() => child.isStatic();

  @override
  Set<Pattern> firstSet() => child.firstSet();
  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  bool singleToken() => child.singleToken();

  @override
  bool match(int? token) => child.match(token);

  @override
  String toString() => "[$precedenceLevel] $child";
}

/// Pattern that labels its child
class Label extends Pattern {
  Label(this.name, Pattern child) : child = child.consume() {
    _start = LabelStart(name);
    _end = LabelEnd(name);
  }
  final String name;
  Pattern child;
  late final LabelStart _start;
  late final LabelEnd _end;

  @override
  Label copy() => Label(name, child.copy());

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    var childEmpty = child.calculateEmpty(emptyRules);
    setEmpty(childEmpty);
    return childEmpty;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {_start};

  @override
  Set<Pattern> lastSet() => {_end};

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    for (var f in child.firstSet()) {
      callback(_start, f);
    }
    child.eachPair(callback);
    for (var l in child.lastSet()) {
      callback(l, _end);
    }
    if (child.empty()) {
      callback(_start, _end);
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => "$name:($child)";
}

class LabelStart extends Pattern {
  LabelStart(this.name);
  final String name;

  @override
  LabelStart copy() => LabelStart(name);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => "label_start($name)";
}

class LabelEnd extends Pattern {
  LabelEnd(this.name);
  final String name;

  @override
  LabelEnd copy() => LabelEnd(name);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {this};

  @override
  Set<Pattern> lastSet() => {this};

  @override
  String toString() => "label_end($name)";
}

// ---------------------------------------------------------------------------
// Convenience extensions for defining precedence in Dart code
// ---------------------------------------------------------------------------

/// Extension to easily attach precedence levels to patterns.
///
/// Usage:
/// ```dart
/// expr = Rule('expr', () {
///   return Token(ExactToken(49)).atLevel(11) |
///       (expr() >> Token(ExactToken(43)) >> expr()).atLevel(6) |
///       (expr() >> Token(ExactToken(42)) >> expr()).atLevel(7);
/// });
/// ```
extension PrecedenceExtension on Pattern {
  /// Wrap this pattern with an explicit precedence level.
  ///
  /// The precedence level determines which alternatives can match when
  /// a rule is called with a minPrecedenceLevel constraint.
  ///
  /// Example:
  /// - `11` - highest precedence (primary expressions, atoms)
  /// - `7` - medium precedence (multiplication, division)
  /// - `6` - lower precedence (addition, subtraction)
  /// - `1` - lowest precedence (assignment-like operators)
  Pattern atLevel(int precedenceLevel) {
    return Prec(precedenceLevel, this);
  }

  /// Alias for [atLevel]. Wrap this pattern with an explicit precedence level.
  Pattern withPrecedence(int precedenceLevel) {
    return Prec(precedenceLevel, this);
  }
}
