/// Pattern system for grammar definition
library glush.patterns;

import 'errors.dart';

sealed class Pattern {
  Pattern();
  factory Pattern.char(String char) = Token.char;
  factory Pattern.string(String pattern) {
    if (pattern.isEmpty) {
      return Eps();
    }

    List<int> codeUnits = pattern.codeUnits;
    Pattern result = codeUnits
        .map((u) => Token(ExactToken(u)))
        .cast<Pattern>()
        .reduce((acc, curr) => acc >> curr)
        .withAction((span, _) => span);

    return result;
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
    throw StateError('empty is not computed for ${runtimeType}');
  }

  /// Set the empty flag (computed by grammar)
  void setEmpty(bool value) {
    _isEmpty = value;
    _isEmptyComputed = true;
  }

  /// Check if this pattern is a single token
  bool singleToken() => false;

  /// Check if the pattern matches a token
  bool match(int? token) {
    throw UnimplementedError('match not implemented for $runtimeType');
  }

  /// Invert this pattern  (matches everything except this)
  Pattern invert() {
    throw UnimplementedError('invert not implemented for $runtimeType');
  }

  /// Calculate if pattern is empty
  bool calculateEmpty(Set<Rule> emptyRules) {
    throw UnimplementedError('calculateEmpty not implemented for $runtimeType');
  }

  /// Check if pattern is "static" (can appear in empty position)
  bool isStatic() {
    throw UnimplementedError('isStatic not implemented for $runtimeType');
  }

  /// Get first set (patterns at the beginning)
  Set<Pattern> firstSet() {
    throw UnimplementedError('firstSet not implemented for $runtimeType');
  }

  /// Get last set (patterns at the end)
  Set<Pattern> lastSet() {
    throw UnimplementedError('lastSet not implemented for $runtimeType');
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
  Action<T> withAction<T>(
      T Function(String span, List<dynamic> childResults) callback) {
    return Action<T>(this, callback);
  }

  static int _customIds = 0;

  /// Repetition operators
  Plus plus() => Plus(this);
  Star star() => Star(this);

  Pattern plusRewrite() {
    late Rule inner;
    inner = Rule(
        "__${_customIds++}",
        () =>
            (inner() >> this).withAction(
                (_, c) => [if (c[0] case List v) ...v else c[0], c[1]]) |
            this);

    return inner();
  }

  Pattern starRewrite() {
    late Rule inner;
    inner = Rule(
        "__${_customIds++}",
        () =>
            (inner() >> this).withAction(
                (_, c) => [if (c[0] case List v) ...v else c[0], c[1]]) |
            Eps());

    return inner();
  }

  Alt maybe() => this | Eps();

  /// Positive lookahead predicate (AND) - succeeds if pattern matches at current position
  /// without consuming input. Allows lookahead without consumption.
  /// Example: &token('a') >> token('a') matches 'a' only when 'a' is present
  And and() => And(this);

  /// Negative lookahead predicate (NOT) - succeeds if pattern does NOT match at current position
  /// without consuming input. Prevents matching when pattern would succeed.
  /// Example: !token('x') >> token('a') matches 'a' only when NOT 'x'
  Not not() => Not(this);

  /// Unary operator for positive lookahead: ~pattern
  And operator ~() => And(this);
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
  String toString() => 'any';
}

/// Matches an exact code-point value
final class ExactToken extends TokenChoice {
  final int value;
  const ExactToken(this.value);
  @override
  bool matches(int? token) => token == value;
  @override
  String toString() => String.fromCharCode(value);
}

/// Matches a code-point within an inclusive range
final class RangeToken extends TokenChoice {
  final int start;
  final int end;
  const RangeToken(this.start, this.end);
  @override
  bool matches(int? token) => token != null && token >= start && token <= end;
  @override
  String toString() => '$start..$end';
}

/// Matches a code-point <= bound
final class LessToken extends TokenChoice {
  final int bound;
  const LessToken(this.bound);
  @override
  bool matches(int? token) => token != null && token <= bound;
  @override
  String toString() => 'less($bound)';
}

/// Matches a code-point >= bound
final class GreaterToken extends TokenChoice {
  final int bound;
  const GreaterToken(this.bound);
  @override
  bool matches(int? token) => token != null && token >= bound;
  @override
  String toString() => 'greater($bound)';
}

/// Single token pattern
class Token extends Pattern {
  final TokenChoice choice;

  Token(this.choice);
  Token.char(String char) //
      : assert(char.length == 1),
        choice = ExactToken(char.codeUnits.first);
  Token.charRange(String from, String to)
      : choice = RangeToken(from.codeUnits.first, to.codeUnits.first);

  @override
  bool singleToken() => true;

  @override
  bool match(int? token) => choice.matches(token);

  @override
  Pattern invert() {
    switch (choice) {
      case ExactToken(:final value):
        return Token(LessToken(value - 1)) | Token(GreaterToken(value + 1));
      case RangeToken(:final start, :final end):
        return Token(LessToken(start - 1)) | Token(GreaterToken(end + 1));
      default:
        throw Exception('Cannot invert $choice');
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
  final String name;

  Marker(this.name);

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
  String toString() => 'mark($name)';
}

/// Epsilon (empty pattern)
class Eps extends Pattern {
  static final Set<Pattern> _emptySet = <Pattern>{};

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
  String toString() => 'eps';
}

/// Alternation (choice between patterns)
class Alt extends Pattern {
  final Pattern left;
  final Pattern right;

  Alt(Pattern left, Pattern right)
      : left = left.consume(),
        right = right.consume();

  @override
  Alt copy() => Alt(left, right);

  @override
  bool singleToken() => left.singleToken() && right.singleToken();

  @override
  bool match(int? token) => left.match(token) || right.match(token);

  @override
  Pattern invert() => left.invert() & right.invert();

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    final leftEmpty = left.calculateEmpty(emptyRules);
    final rightEmpty = right.calculateEmpty(emptyRules);
    final result = leftEmpty || rightEmpty;
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
  String toString() => 'alt($left, $right)';
}

/// Sequence (patterns in order)
class Seq extends Pattern {
  final Pattern left;
  final Pattern right;

  Seq(Pattern left, Pattern right)
      : left = left.consume(),
        right = right.consume();

  @override
  Seq copy() => Seq(left, right);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    final leftEmpty = left.calculateEmpty(emptyRules);
    final rightEmpty = right.calculateEmpty(emptyRules);
    final result = leftEmpty && rightEmpty;
    setEmpty(result);
    return result;
  }

  @override
  bool isStatic() => left.isStatic() && right.isStatic();

  @override
  Set<Pattern> firstSet() {
    final leftFirst = left.firstSet();
    if (left.empty()) {
      return {...leftFirst, ...right.firstSet()};
    }
    return leftFirst;
  }

  @override
  Set<Pattern> lastSet() {
    final rightLast = right.lastSet();
    if (right.empty()) {
      return {...left.lastSet(), ...rightLast};
    }
    return rightLast;
  }

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    left.eachPair(callback);
    right.eachPair(callback);

    for (final a in left.lastSet()) {
      for (final b in right.firstSet()) {
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
  String toString() => 'seq($left, $right)';
}

/// Conjunction (both patterns must match)
class Conj extends Pattern {
  final Pattern left;
  final Pattern right;

  Conj(Pattern left, Pattern right)
      : left = left.consume(),
        right = right.consume() {
    if (!left.singleToken() || !right.singleToken()) {
      throw GrammarError('only single token can be used in conjunctions');
    }
  }

  @override
  bool singleToken() => true;

  @override
  bool match(int? token) => left.match(token) && right.match(token);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => false;

  @override
  Set<Pattern> firstSet() => {this};
  @override
  Set<Pattern> lastSet() => {this};

  @override
  Conj copy() => Conj(left, right);

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  String toString() => 'conj($left, $right)';
}

/// Repetition (one or more)
class Plus extends Pattern {
  final Pattern child;

  Plus(Pattern c) : child = c.consume();

  @override
  Plus copy() => Plus(child);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    final childEmpty = child.calculateEmpty(emptyRules);
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
    for (final a in child.lastSet()) {
      for (final b in child.firstSet()) {
        callback(a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => 'plus($child)';
}

/// Repetition (zero or more)
class Star extends Pattern {
  final Pattern child;

  Star(Pattern c) : child = c.consume();

  @override
  Star copy() => Star(child);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    child.calculateEmpty(emptyRules);
    setEmpty(true);
    return true;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => child.firstSet();
  @override
  Set<Pattern> lastSet() => child.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    child.eachPair(callback);
    for (final a in child.lastSet()) {
      for (final b in child.firstSet()) {
        callback(a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  String toString() => 'star($child)';
}

/// Positive lookahead predicate (AND) - matches if pattern succeeds without consuming
/// Example: &('a' >> 'b') >> 'a' will only match 'a' if followed by 'b'
class And extends Pattern {
  final Pattern pattern;

  And(Pattern p) : pattern = p.consume();

  @override
  And copy() => And(pattern);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // A predicate always matches without consuming, so it's never empty in terms of requiring input
    // But for epsilon purposes, it depends on the child pattern
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
  String toString() => 'and($pattern)';
}

/// Negative lookahead predicate (NOT) - matches if pattern fails without consuming
/// Example: !('a' >> 'b') >> 'a' will only match 'a' if NOT followed by 'b'
class Not extends Pattern {
  final Pattern pattern;

  Not(Pattern p) : pattern = p.consume();

  @override
  Not copy() => Not(pattern);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // A predicate always matches without consuming, so it's never empty in terms of requiring input
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
  String toString() => 'not($pattern)';
}

/// Grammar rule
class Rule extends Pattern {
  final String name;
  final Pattern Function() _code;
  Pattern? _body;
  Pattern? guard;
  final List<RuleCall> calls = [];

  Rule(this.name, this._code);

  RuleCall call({int? minPrecedenceLevel}) {
    final name = '${this.name}_${calls.length}';
    final call = RuleCall(name, this, minPrecedenceLevel: minPrecedenceLevel);
    calls.add(call);
    return call;
  }

  Pattern body() {
    if (_body == null) {
      _body = _code().consume();
    }
    return _body!;
  }

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    setEmpty(body().calculateEmpty(emptyRules));
    return _isEmpty ?? false;
  }

  @override
  Rule copy() => Rule(name, _code);

  @override
  Set<Pattern> firstSet() => {this};
  @override
  Set<Pattern> lastSet() => {this};

  @override
  bool isStatic() => false;

  @override
  String toString() => '<$name>';
}

/// Call to a rule with optional precedence constraint
class RuleCall extends Pattern {
  final String name;
  final Rule rule;

  /// Minimum precedence level filter. If set, only alternatives in the rule
  /// with precedenceLevel >= minPrecedenceLevel will match.
  /// This implements EXPR^N syntax where N is the minimum precedence level.
  final int? minPrecedenceLevel;

  RuleCall(this.name, this.rule, {this.minPrecedenceLevel});

  @override
  RuleCall copy() =>
      RuleCall(name, rule, minPrecedenceLevel: minPrecedenceLevel);

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
  String toString() =>
      minPrecedenceLevel != null ? '<$name^$minPrecedenceLevel>' : '<$name>';
}

/// Lazy call to a rule (defers the call until needed), with optional precedence constraint
class Call extends Pattern {
  final Rule rule;

  /// Minimum precedence level filter. If set, only alternatives in the ruled
  /// with precedenceLevel >= minPrecedenceLevel will match.
  final int? minPrecedenceLevel;

  Call(this.rule, {this.minPrecedenceLevel});

  @override
  Call copy() => Call(rule, minPrecedenceLevel: minPrecedenceLevel);

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
  String toString() => minPrecedenceLevel != null
      ? '<${rule.name}^$minPrecedenceLevel>'
      : '<${rule.name}>';
}

/// Semantic action pattern - executes a callback when child pattern matches.
/// The callback receives (span, childResults) where childResults are the evaluated semantic values.
class Action<T> extends Pattern {
  final Pattern child;
  final T Function(String span, List<dynamic> childResults) callback;

  Action(this.child, this.callback);

  @override
  Action<T> copy() => Action<T>(child.copy(), callback);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    final childEmpty = child.calculateEmpty(emptyRules);
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
  String toString() => 'action($child)';
}

/// Pattern labeled with a precedence level for operator precedence parsing.
/// When this pattern is part of a rule body alternation, the precedence level
/// determines which alternatives can match based on precedence constraints.
/// Example: In "6| $add EXPR^6 ... EXPR^7", the entire sequence gets precedenceLevel=6
class PrecedenceLabeledPattern extends Pattern {
  final int precedenceLevel;
  final Pattern pattern;

  PrecedenceLabeledPattern(this.precedenceLevel, this.pattern);

  @override
  PrecedenceLabeledPattern copy() =>
      PrecedenceLabeledPattern(precedenceLevel, pattern.copy());

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    final childEmpty = pattern.calculateEmpty(emptyRules);
    setEmpty(childEmpty);
    return childEmpty;
  }

  @override
  bool isStatic() => pattern.isStatic();

  @override
  Set<Pattern> firstSet() => pattern.firstSet();
  @override
  Set<Pattern> lastSet() => pattern.lastSet();

  @override
  void eachPair(void Function(Pattern, Pattern) callback) {
    pattern.eachPair(callback);
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  bool singleToken() => pattern.singleToken();

  @override
  bool match(int? token) => pattern.match(token);

  @override
  String toString() => '[$precedenceLevel] $pattern';
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
///       (Call(expr) >> Token(ExactToken(43)) >> Call(expr)).atLevel(6) |
///       (Call(expr) >> Token(ExactToken(42)) >> Call(expr)).atLevel(7);
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
    return PrecedenceLabeledPattern(precedenceLevel, this);
  }

  /// Alias for [atLevel]. Wrap this pattern with an explicit precedence level.
  Pattern withPrecedence(int precedenceLevel) {
    return atLevel(precedenceLevel);
  }
}
