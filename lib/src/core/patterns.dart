// ignore_for_file: avoid_positional_boolean_parameters, use_to_and_as_if_applicable

/// Pattern system for grammar definition
library glush.patterns;

import "dart:convert";

import "package:glush/src/compiler/errors.dart";
import "package:glush/src/core/profiling.dart";

typedef PatternSymbol = int;

/// The abstract base class for all grammar patterns in the Glush system.
///
/// A [Pattern] defines a fragment of a grammar that can be matched against
/// an input stream. It includes primitive tokens, anchors, and higher-level
/// combinators like sequences and alternations. The pattern system is designed
/// to be extensible and allows for complex semantic extensions such as
/// actions, guards, and conjunctions.
sealed class Pattern {
  /// Base constructor for [Pattern].
  Pattern();

  /// Creates a [Token] pattern that matches a single character.
  factory Pattern.char(String char) = Token.char;

  /// Creates an anchor that matches only at the start of the stream.
  factory Pattern.start() = StartAnchor;

  /// Creates an anchor that matches only at the end of the stream.
  factory Pattern.eof() = EofAnchor;

  /// Creates a token that matches any single character.
  factory Pattern.any() = Token.any;

  /// Creates a retreat pattern that moves the parse position backward.
  factory Pattern.retreat() = Retreat;

  /// Creates a [Pattern] from a string literal.
  ///
  /// This factory converts a string into a sequence of tokens. If the string
  /// is empty, it returns an epsilon ([Eps]) pattern.
  factory Pattern.string(String pattern) {
    if (pattern.isEmpty) {
      return Eps();
    }

    List<int> bytes = utf8.encode(pattern);

    if (bytes.length == 1) {
      return Token(ExactToken(bytes.single));
    }

    Pattern result = bytes
        .map((b) => Token(ExactToken(b)))
        .cast<Pattern>()
        .reduce((acc, curr) => acc >> curr);

    return result;
  }

  /// Deserializes a [Pattern] from its JSON representation.
  factory Pattern.fromJson(Map<String, Object?> json, Map<String, Rule> ruleMap) {
    var type = json["type"]! as String;
    Pattern pattern = switch (type) {
      "tok" => Token.fromJson(json),
      "bos" => StartAnchor(),
      "eof" => EofAnchor(),
      "eps" => Eps(),
      "alt" => Alt(
        Pattern.fromJson(json["left"]! as Map<String, Object?>, ruleMap),
        Pattern.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      ),
      "seq" => Seq(
        Pattern.fromJson(json["left"]! as Map<String, Object?>, ruleMap),
        Pattern.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      ),
      "con" => Conj(
        Pattern.fromJson(json["left"]! as Map<String, Object?>, ruleMap),
        Pattern.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      ),
      "and" => And(Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      "not" => Not(Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      "rca" => RuleCall(
        json["name"]! as String,
        ruleMap[json["ruleName"]] ??
            (throw StateError(
              "Rule '${json["ruleName"]}' not found in ruleMap. Keys are: ${ruleMap.keys.toList()}",
            )),
        minPrecedenceLevel: json["minPrecedenceLevel"] as int?,
      ),
      "pre" => Prec(
        json["precedenceLevel"]! as int,
        Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap),
      ),
      "opt" => Opt(Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      "plu" => Plus(Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      "sta" => Star(Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      "lab" => Label(
        json["name"]! as String,
        Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap),
      ),
      "las" => LabelStart(json["name"]! as String),
      "lae" => LabelEnd(json["name"]! as String),
      "ret" => Retreat(),
      _ => throw UnsupportedError("Unknown pattern type: $type"),
    };
    if (json["symbolId"] != null) {
      pattern.symbolId = json["symbolId"]! as int;
    }
    return pattern;
  }

  /// Serializes this pattern to JSON.
  Map<String, Object?> toJson() => {"type": _symbolPrefix, "symbolId": symbolId};

  /// A unique ID assigned to this pattern during grammar compilation.
  ///
  /// This ID is used by the state machine to identify transitions
  /// and nodes efficiently without object identity overhead.
  PatternSymbol? symbolId;

  bool? _isEmptyComputed;
  bool? _isEmpty;
  bool _consumed = false;

  /// Creates a copy of this pattern with reset state.
  Pattern copy();

  /// Marks this pattern as consumed in the current branch.
  Pattern consume() {
    if (_consumed) {
      return copy().consume();
    }
    _consumed = true;
    return this;
  }

  /// Returns whether this pattern can match an empty input (epsilon).
  ///
  /// This is computed during the grammar's normalization phase and is
  /// essential for correct first/last set calculation and nullability analysis.
  bool empty() {
    if (_isEmptyComputed != null) {
      return _isEmpty ?? false;
    }
    throw StateError("empty is not computed for $runtimeType");
  }

  /// Manually sets the nullability status of this pattern.
  void setEmpty(bool value) {
    _isEmpty = value;
    _isEmptyComputed = true;
  }

  /// Whether this pattern represents a single atomic token.
  bool singleToken() => false;

  /// Whether this pattern matches the provided [token].
  bool match(int? token) {
    throw UnimplementedError("match not implemented for $runtimeType");
  }

  /// Returns a pattern that matches the inverse of this one.
  Pattern invert() {
    throw UnimplementedError("invert not implemented for $runtimeType");
  }

  /// Calculates the nullability of this pattern based on rule references.
  bool calculateEmpty(Set<Rule> emptyRules) {
    throw UnimplementedError("calculateEmpty not implemented for $runtimeType");
  }

  /// Whether this pattern is "static" (matches a zero-width span at any position).
  ///
  /// This is true for epsilon, anchors, and markers.
  bool isStatic() {
    throw UnimplementedError("isStatic not implemented for $runtimeType");
  }

  /// Returns the set of initial sub-patterns that can start a match of this pattern.
  Set<Pattern> firstSet() {
    throw UnimplementedError("firstSet not implemented for $runtimeType");
  }

  /// Returns the set of final sub-patterns that can complete a match of this pattern.
  Set<Pattern> lastSet() {
    throw UnimplementedError("lastSet not implemented for $runtimeType");
  }

  /// Yields all internal connections (a, b) where pattern 'a' can be followed by 'b'.
  Iterable<(Pattern, Pattern)> eachPair() sync* {}

  /// Collects all [Rule]s that this pattern recursively refers to.
  void collectRules(Set<Rule> rules) {}

  /// DSL operator for sequential composition ([Seq]).
  Seq operator >>(Pattern other) => Seq(this, other);

  /// DSL operator for alternation ([Alt]).
  Alt operator |(Pattern other) => Alt(this, other);

  /// DSL operator for parallel conjunction ([Conj]).
  Conj operator &(Pattern other) => Conj(this, other);

  /// Retreat operator — verifies this pattern matches, then moves the
  /// parsing position back by one before continuing.
  Pattern operator <(Pattern other) => this >> Retreat() >> other;

  /// DSL helper for one-or-more repetition ([Plus]).
  Pattern plus() => Plus(this);

  /// DSL helper for zero-or-more repetition ([Star]).
  Pattern star() => Star(this);

  /// DSL helper for optional matches ([Opt]).
  Pattern opt() => Opt(this);

  /// Internal tag used for JSON serialization and discrimination.
  String get _symbolPrefix {
    return switch (this) {
      Token() => "tok",
      StartAnchor() => "bos",
      EofAnchor() => "eof",
      Eps() => "eps",
      Alt() => "alt",
      Seq() => "seq",
      Conj() => "con",
      And() => "and",
      Not() => "not",
      Rule() => "rul",
      RuleCall() => "rca",
      Prec() => "pre",
      Opt() => "opt",
      Plus() => "plu",
      Star() => "sta",
      Label() => "lab",
      LabelStart() => "las",
      LabelEnd() => "lae",
      Retreat() => "ret",
    };
  }

  /// DSL helper for an optional variant of this pattern.
  Alt maybe() => this | Eps();

  /// DSL helper for positive lookahead (AND predicate).
  And and() => And(this);

  /// DSL helper for negative lookahead (NOT predicate).
  Not not() => Not(this);
}

/// Sealed class hierarchy for token choice — replaces the former Object? field.
/// Abstract base for defining how a token choice matches input.
sealed class TokenChoice {
  /// Base constructor for [TokenChoice].
  const TokenChoice(this.capturesAsMark);

  /// Deserializes a [TokenChoice] from JSON.
  factory TokenChoice.fromJson(Map<String, Object?> json) {
    var type = json["type"]! as String;
    return switch (type) {
      "any" => const AnyToken(),
      "exact" => ExactToken(json["value"]! as int),
      "range" => RangeToken(json["start"]! as int, json["end"]! as int),
      "less" => LessToken(json["bound"]! as int),
      "greater" => GreaterToken(json["bound"]! as int),
      "not" => NotToken(TokenChoice.fromJson(json["inner"]! as Map<String, Object?>)),
      _ => throw UnsupportedError("Unknown token choice type: $type"),
    };
  }

  /// Serializes this choice to JSON.
  Map<String, Object?> toJson();

  /// Whether this choice should be automatically wrapped in a mark when captured.
  final bool capturesAsMark;

  /// Returns true if this choice matches the provided [value].
  bool matches(int? value);
}

/// Matches any token (wildcard)
final class AnyToken extends TokenChoice {
  const AnyToken() : super(true);

  @override
  bool matches(int? value) => value != null;

  @override
  String toString() => "any";

  @override
  Map<String, Object?> toJson() => {"type": "any"};
}

final class NotToken extends TokenChoice {
  const NotToken(this.inner) : super(true);
  final TokenChoice inner;

  @override
  bool matches(int? value) => !inner.matches(value);

  @override
  String toString() => "not($inner)";

  @override
  Map<String, Object?> toJson() => {"type": "not", "inner": inner.toJson()};
}

/// Matches an exact code-point value
final class ExactToken extends TokenChoice {
  const ExactToken(this.value) : super(false);
  final int value;

  @override
  bool matches(int? token) => token == value;

  @override
  String toString() => String.fromCharCode(value);

  @override
  Map<String, Object?> toJson() => {"type": "exact", "value": value};
}

/// Matches a code-point within an inclusive range
final class RangeToken extends TokenChoice {
  const RangeToken(this.start, this.end) : super(true);
  final int start;
  final int end;

  @override
  bool matches(int? token) => token != null && token >= start && token <= end;

  @override
  String toString() => "$start..$end";

  @override
  Map<String, Object?> toJson() => {"type": "range", "start": start, "end": end};
}

/// Matches a code-point <= bound
final class LessToken extends TokenChoice {
  const LessToken(this.bound) : super(true);
  final int bound;

  @override
  bool matches(int? token) => token != null && token <= bound;

  @override
  String toString() => "less($bound)";

  @override
  Map<String, Object?> toJson() => {"type": "less", "bound": bound};
}

/// Matches a code-point >= bound
final class GreaterToken extends TokenChoice {
  const GreaterToken(this.bound) : super(true);
  final int bound;

  @override
  bool matches(int? token) => token != null && token >= bound;

  @override
  String toString() => "greater($bound)";

  @override
  Map<String, Object?> toJson() => {"type": "greater", "bound": bound};
}

/// A pattern that matches a single atomic token from the input stream.
class Token extends Pattern {
  /// Creates a [Token] with the specified [choice] logic.
  Token(this.choice);

  /// Deserializes a [Token] from JSON.
  factory Token.fromJson(Map<String, Object?> json) {
    return Token(TokenChoice.fromJson(json["choice"]! as Map<String, Object?>));
  }

  /// Creates a [Token] matching a single character [char].
  Token.char(String char) //
    : assert(char.length == 1, "Character patterns should have only one value!"),
      choice = ExactToken(utf8.encode(char).single);

  /// Creates a [Token] matching a range of characters from [from] to [to].
  Token.charRange(String from, String to)
    : choice = RangeToken(utf8.encode(from).first, utf8.encode(to).first);

  /// Creates a [Token] that matches any single character.
  Token.any() : choice = const RangeToken(0, 255);

  /// The matching logic for this token.
  final TokenChoice choice;

  @override
  bool singleToken() => true;

  @override
  bool match(int? token) => choice.matches(token);

  /// Whether this token's captures should be treated as marks.
  bool get capturesAsMark => choice.capturesAsMark;

  @override
  Map<String, Object?> toJson() => {"type": "tok", "choice": choice.toJson()};

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

/// The empty pattern (epsilon).
///
/// This pattern always matches successfully without consuming any input. It is
/// the identity element for sequential composition.
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
  Map<String, Object?> toJson() => {"type": "eps"};

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
  Map<String, Object?> toJson() => {"type": "bos"};

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
  Map<String, Object?> toJson() => {"type": "eof"};

  @override
  String toString() => r"$";
}

/// Retreat (backstep) pattern.
///
/// Matches at any position and moves the parsing position back by one.
/// Useful for lookahead/backtrack patterns where match validation is separated
/// from consumption.
final class Retreat extends Pattern {
  @override
  Retreat copy() => Retreat();

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
  Map<String, Object?> toJson() => {"type": "ret"};

  @override
  String toString() => "<";
}

/// A pattern that matches one of two alternative patterns.
///
/// [Alt] implements ordered choice by default in some engines, but in Glush it
/// represents a branch in the parse forest. If both patterns match, the result
/// is ambiguous unless disambiguated by precedence or other guards.
class Alt extends Pattern {
  /// Creates an [Alt] between [left] and [right] patterns.
  Alt(Pattern left, Pattern right) : left = left.consume(), right = right.consume();

  /// The first alternative pattern.
  Pattern left;

  /// The second alternative pattern.
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
    } on GrammarError {
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* left.eachPair();
    yield* right.eachPair();
  }

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "alt", "left": left.toJson(), "right": right.toJson()};

  @override
  String toString() => "alt($left, $right)";
}

/// A pattern that matches two patterns in sequence.
///
/// [Seq] is the fundamental building block of hierarchical grammars,
/// ensuring that the [left] pattern is fully matched before the [right]
/// pattern begins.
class Seq extends Pattern {
  /// Creates a [Seq] of [left] followed by [right].
  Seq(Pattern left, Pattern right) : left = left.consume(), right = right.consume();

  /// The pattern that must match first.
  Pattern left;

  /// The pattern that must match second.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* left.eachPair();
    yield* right.eachPair();

    for (var a in left.lastSet()) {
      for (var b in right.firstSet()) {
        yield (a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "seq", "left": left.toJson(), "right": right.toJson()};

  @override
  String toString() => "seq($left, $right)";
}

/// A pattern that matches a child pattern zero or one times.
///
/// [Opt] is a first-class node in Glush to preserve the original grammar's
/// structure for better error reporting, rather than
/// immediately lowering it to an [Alt] with epsilon.
class Opt extends Pattern {
  /// Creates an [Opt] wrapping the [child] pattern.
  Opt(Pattern child) : child = child.consume();

  /// The optional child pattern.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "opt", "child": child.toJson()};

  @override
  String toString() => "opt($child)";
}

/// A pattern that matches a child pattern zero or more times.
///
/// [Star] (Kleene Star) represents a repeating loop in the grammar. In Glush,
/// this is handled by the state machine's back-edges and epsilon transitions.
class Star extends Pattern {
  /// Creates a [Star] wrapping the [child] pattern.
  Star(Pattern child) : child = child.consume();

  /// The repeating child pattern.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();

    // Loopback edges: any pattern at the end of the child can be followed
    // by any pattern at the start of the child.
    for (var a in child.lastSet()) {
      for (var b in child.firstSet()) {
        yield (a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "star", "child": child.toJson()};

  @override
  String toString() => "star($child)";
}

/// A pattern that matches a child pattern one or more times.
///
/// [Plus] is similar to [Star] but requires at least one successful match
/// of the [child].
class Plus extends Pattern {
  /// Creates a [Plus] wrapping the [child] pattern.
  Plus(Pattern child) : child = child.consume();

  /// The repeating child pattern.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();

    // Loopback edges similar to Star.
    for (var a in child.lastSet()) {
      for (var b in child.firstSet()) {
        yield (a, b);
      }
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "plu", "child": child.toJson()};

  @override
  String toString() => "plus($child)";
}

/// A pattern representing the parallel conjunction of two patterns.
///
/// In a conjunction, BOTH [left] and [right] must match the exact same span
/// of input for the conjunction to succeed. This is used for context-sensitive
/// checks, refined tokenization, or implementing Boolean grammars.
class Conj extends Pattern {
  /// Creates a [Conj] of [left] and [right].
  Conj(Pattern left, Pattern right) : left = left.consume(), right = right.consume();

  /// The first pattern to verify.
  Pattern left;

  /// The second pattern to verify.
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
  Map<String, Object?> toJson() => {"type": "con", "left": left.toJson(), "right": right.toJson()};

  @override
  String toString() => "conj($left, $right)";
}

/// A positive lookahead predicate (syntactic AND).
///
/// Succeeds if the [pattern] matches at the current position, but does NOT
/// consume any input. This allows for checking future input without moving
/// the parse head.
class And extends Pattern {
  /// Creates an [And] lookahead wrapping [p].
  And(Pattern p) : pattern = p.consume();

  /// The lookahead pattern.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    // Predicates don't participate in normal eachPair flow
    // They're checked independently
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "and", "child": pattern.toJson()};

  @override
  String toString() => "and($pattern)";
}

/// A negative lookahead predicate (syntactic NOT).
///
/// Succeeds if the [pattern] does NOT match at the current position. Like [And],
/// it does not consume any input.
class Not extends Pattern {
  /// Creates a [Not] lookahead wrapping [p].
  Not(Pattern p) : pattern = p.consume();

  /// The lookahead pattern to be negated.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    // Predicates don't participate in normal eachPair flow
    // They're checked independently
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "not", "child": pattern.toJson()};

  @override
  String toString() => "not($pattern)";
}

extension type RuleName(String symbol) {}

/// A high-level grammar rule that encapsulates a parsing fragment.
///
/// Rules are the primary unit of reuse in a grammar. They can be recursive
/// and guarded. A rule has a [name] and a [body] (the pattern it
/// implements), and it can be called from other patterns using [RuleCall].
class Rule extends Pattern {
  /// Creates a [Rule] with a [name] and a [_code] thunk for its body.
  Rule(String name, this._code) : name = RuleName(name), uid = _uidCounter++;

  static int _uidCounter = 1;

  /// The unique name of this rule within the grammar.
  final RuleName name;

  /// The thunk that generates the rule's body pattern.
  final Pattern Function() _code;

  /// A list of all calls made to this rule, used for tracking and expansion.
  final List<RuleCall> calls = [];

  /// A unique numeric ID for fast indexing in the state machine caches.
  final int uid;

  Pattern? _body;

  /// Creates a [RuleCall] to this rule with the given [minPrecedenceLevel].
  RuleCall call({int? minPrecedenceLevel}) {
    var name = "${this.name}_${calls.length}";
    var call = RuleCall(name, this, minPrecedenceLevel: minPrecedenceLevel);
    calls.add(call);
    return call;
  }

  /// Evaluates the thunk and returns the rule's [Pattern] body.
  ///
  /// The body is memoized after the first call to avoid redundant evaluations.
  Pattern body() {
    if (_body == null) {
      _body = _code().consume();
      GlushProfiler.increment("parser.rule_body.created");
    }
    return _body!;
  }

  /// Manually overrides the rule's body pattern.
  // ignore: use_setters_to_change_properties
  void setBody(Pattern body) {
    _body = body;
  }

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // We MUST still call calculateEmpty on the body to ensure all nested
    // patterns (Tokens, etc.) have their empty status initialized.
    var bodyEmpty = body().calculateEmpty(emptyRules);

    setEmpty(bodyEmpty);
    return bodyEmpty;
  }

  @override
  Rule copy() {
    var copy = Rule(name.symbol, _code);
    copy._body = _body;
    return copy;
  }

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
  Map<String, Object?> toJson() => {"type": "rul", "ruleName": name.symbol, "symbolId": symbolId};

  @override
  String toString() => "<$name>";
}

/// An invocation of a rule within another pattern.
///
/// [RuleCall] represents a specific use of a rule, potentially with
/// [minPrecedenceLevel] for disambiguation.
class RuleCall extends Pattern {
  /// Creates a [RuleCall] to the specified [rule].
  RuleCall(this.name, this.rule, {this.minPrecedenceLevel});

  /// A local name for this call instance.
  final String name;

  /// The rule being called.
  final Rule rule;

  /// Minimum precedence level filter.
  ///
  /// If set, only alternatives in the rule with precedenceLevel >=
  /// minPrecedenceLevel will match. This implements EXPR^N syntax.
  final int? minPrecedenceLevel;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    "name": name,
    "ruleName": rule.name.symbol,
    "minPrecedenceLevel": minPrecedenceLevel,
    "symbolId": symbolId,
  };

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
  }

  @override
  String toString() {
    var prec = minPrecedenceLevel != null ? "^$minPrecedenceLevel" : "";
    return "<$name$prec>";
  }
}

/// A pattern that assigns a precedence level to its child.
///
/// Precedence levels are used by the [Rule] system and [RuleCall] to disambiguate
/// grammars using the EXPR^N syntax. When multiple alternatives in a rule
/// could match, the ones with the highest [precedenceLevel] are preferred
/// according to the minPrecedenceLevel constraint of the caller.
class Prec extends Pattern {
  /// Creates a [Prec] wrapper with [precedenceLevel] for [child].
  Prec(this.precedenceLevel, this.child);

  /// The numeric precedence level (higher values typically bind tighter).
  final int precedenceLevel;

  /// The child pattern being labeled.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();
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
  Map<String, Object?> toJson() => {
    "type": "pre",
    "precedenceLevel": precedenceLevel,
    "child": child.toJson(),
  };

  @override
  String toString() => "[$precedenceLevel] $child";
}

/// A pattern that labels its child with a [name] for capture.
///
/// Labeled patterns are used to extract specific parts of a match for evaluation
class Label extends Pattern {
  /// Creates a [Label] with the given [name] for [child].
  Label(this.name, Pattern child) : child = child.consume() {
    _start = LabelStart(name);
    _end = LabelEnd(name);
  }

  /// The capture name.
  final String name;

  /// The pattern being labeled.
  Pattern child;

  late final LabelStart _start;
  late final LabelEnd _end;

  @override
  Label copy() => Label(name, child.copy());

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    (_) = child.calculateEmpty(emptyRules);
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => true;

  @override
  Set<Pattern> firstSet() => {_start};

  @override
  Set<Pattern> lastSet() => {_end};

  @override
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    for (var f in child.firstSet()) {
      yield (_start, f);
    }
    yield* child.eachPair();
    for (var l in child.lastSet()) {
      yield (l, _end);
    }
    if (child.empty()) {
      yield (_start, _end);
    }
  }

  @override
  void collectRules(Set<Rule> rules) {
    child.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {"type": "lab", "name": name, "child": child.toJson()};

  @override
  String toString() => "$name:($child)";
}

/// A marker pattern indicating the start of a labeled span.
class LabelStart extends Pattern {
  /// Creates a [LabelStart] for [name].
  LabelStart(this.name);

  /// The name of the label.
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
  Map<String, Object?> toJson() => {"type": "las", "name": name};

  @override
  String toString() => "label_start($name)";
}

/// A marker pattern indicating the end of a labeled span.
class LabelEnd extends Pattern {
  /// Creates a [LabelEnd] for [name].
  LabelEnd(this.name);

  /// The name of the label.
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
  Map<String, Object?> toJson() => {"type": "lae", "name": name};

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
