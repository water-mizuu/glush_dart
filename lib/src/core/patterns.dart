// ignore_for_file: avoid_positional_boolean_parameters, use_to_and_as_if_applicable

/// Pattern system for grammar definition
library glush.patterns;

import "dart:convert";

import "package:glush/src/compiler/errors.dart";
import "package:glush/src/compiler/format.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/profiling.dart";
import "package:meta/meta.dart";

/// Abstract base class for keys used to identify and memoize rule calls with arguments.
///
/// In a grammar with parameterized rules, the identity of a rule call is not
/// just the rule name, but the name combined with its specific arguments.
/// [CallArgumentsKey] provides a way to uniquely identify these combinations.
@immutable
sealed class CallArgumentsKey {
  /// Base constructor for [CallArgumentsKey].
  const CallArgumentsKey();
}

/// A [CallArgumentsKey] that represents a simple string-based identifier.
final class StringCallArgumentsKey extends CallArgumentsKey {
  /// Creates a [StringCallArgumentsKey] with the given [key].
  const StringCallArgumentsKey(this.key);

  /// The raw string key.
  final String key;

  @override
  bool operator ==(Object other) => other is StringCallArgumentsKey && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// A [CallArgumentsKey] representing an empty set of arguments.
///
/// This is used for standard rule calls that don't take any parameters.
final class EmptyCallArgumentsKey extends CallArgumentsKey {
  /// Creates an [EmptyCallArgumentsKey].
  const EmptyCallArgumentsKey();

  @override
  bool operator ==(Object other) => other is EmptyCallArgumentsKey;

  @override
  int get hashCode => (EmptyCallArgumentsKey).hashCode;

  @override
  String toString() => "";
}

/// A complex [CallArgumentsKey] used for guarding and memoizing semantic predicates.
///
/// This key includes information about the capture signature, rule context,
/// and precedence levels to ensure that guards are evaluated correctly
/// across different parsing contexts.
final class GuardValuesKey extends CallArgumentsKey {
  /// Creates a [GuardValuesKey] with all necessary context for a guard.
  const GuardValuesKey({
    required this.captureSignature,
    required this.ruleName,
    required this.position,
    required this.callStart,
    required this.minPrecedenceLevel,
    required this.precedenceLevel,
  });

  /// A canonical signature of the captures available in the guard's scope.
  final String captureSignature;

  /// The name of the rule containing the guard.
  final RuleName ruleName;

  /// The current position in the input stream.
  final int position;

  /// The starting position of the current rule call.
  final int callStart;

  /// The minimum precedence level allowed in the current context.
  final int? minPrecedenceLevel;

  /// The specific precedence level of the current expression.
  final int? precedenceLevel;

  @override
  bool operator ==(Object other) =>
      other is GuardValuesKey &&
      other.captureSignature == captureSignature &&
      other.ruleName == ruleName &&
      other.position == position &&
      other.callStart == callStart &&
      other.minPrecedenceLevel == minPrecedenceLevel &&
      other.precedenceLevel == precedenceLevel;

  @override
  int get hashCode => Object.hash(
    captureSignature,
    ruleName,
    position,
    callStart,
    minPrecedenceLevel,
    precedenceLevel,
  );
}

/// A [CallArgumentsKey] that aggregates multiple values into a single identity.
final class CompositeCallArgumentsKey extends CallArgumentsKey {
  /// Creates a [CompositeCallArgumentsKey] from a list of [values].
  const CompositeCallArgumentsKey(this.values);

  /// The list of values contributing to the key's identity.
  final List<Object?> values;

  @override
  bool operator ==(Object other) =>
      other is CompositeCallArgumentsKey &&
      other.values.length == values.length &&
      Iterable<int>.generate(values.length).every((i) => other.values[i] == values[i]);

  @override
  int get hashCode => Object.hashAll(values);

  @override
  String toString() => values.join(",");
}

/// A [CallArgumentsKey] that combines two existing keys.
///
/// This is used when a rule call inherits arguments from its caller and
/// adds its own local arguments.
final class MergedCallArgumentsKey extends CallArgumentsKey {
  /// Creates a [MergedCallArgumentsKey] from [left] and [right] components.
  const MergedCallArgumentsKey(this.left, this.right);

  /// The primary (often inherited) key.
  final CallArgumentsKey? left;

  /// The secondary (often local) key.
  final CallArgumentsKey? right;

  @override
  bool operator ==(Object other) =>
      other is MergedCallArgumentsKey && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(left, right);
}

typedef PatternSymbol = int;

String _callArgumentSourceKey(Map<String, CallArgumentValue> arguments) {
  // The source key is a canonical description of the call arguments so the
  // caller cache can treat differently ordered named arguments as identical.
  var entries = arguments.entries.toList()..sort(_compareCallArgumentEntriesByKey);
  var buffer = StringBuffer();
  buffer.write("m");
  buffer.write(entries.length);
  buffer.write("{");
  for (var i = 0; i < entries.length; i++) {
    if (i != 0) {
      buffer.write(",");
    }
    var entry = entries[i];
    _writeCanonicalString(buffer, entry.key);
    buffer.write("=");
    buffer.write(entry.value.format());
  }
  buffer.write("}");
  return buffer.toString();
}

List<String> _sortedArgumentNames(
  Iterable<String> fixedArguments,
  Iterable<String> dynamicArguments,
) {
  var names = <String>{...fixedArguments, ...dynamicArguments}.toList()..sort();
  return List<String>.unmodifiable(names);
}

void _writeCanonicalString(StringBuffer buffer, String value) {
  buffer
    ..write("s")
    ..write(value.length)
    ..write(":")
    ..write(value);
}

void _writeCanonicalEntry(StringBuffer buffer, String key, Object? value) {
  _writeCanonicalString(buffer, key);
  buffer.write("=");
  _writeCanonicalValue(buffer, value);
}

int _compareMapEntriesByKey(MapEntry<String, Object?> left, MapEntry<String, Object?> right) {
  return left.key.compareTo(right.key);
}

int _compareCallArgumentEntriesByKey(
  MapEntry<String, CallArgumentValue> left,
  MapEntry<String, CallArgumentValue> right,
) {
  return left.key.compareTo(right.key);
}

void _writeCanonicalValue(StringBuffer buffer, Object? value) {
  switch (value) {
    case CallArgumentValue argument:
      buffer.write("a");
      _writeCanonicalString(buffer, argument.format());
    case null:
      buffer.write("n");
    case bool():
      buffer.write(value ? "b1" : "b0");
    case int():
      buffer
        ..write("i")
        ..write(value);
    case double():
      buffer
        ..write("d")
        ..write(value.toString());
    case String():
      _writeCanonicalString(buffer, value);
    case Rule(:var name):
      buffer.write("r");
      _writeCanonicalString(buffer, name.toString());
    case PatternClosureValue(:var key):
      buffer.write("c");
      _writeCanonicalString(buffer, key);
    case CaptureValue(:var startPosition, :var value):
      buffer.write("cap");
      buffer.write(startPosition);
      buffer.write(":");
      _writeCanonicalString(buffer, value);
    case ParameterCallPattern(:var name, :var argumentsKey):
      buffer.write("pa");
      _writeCanonicalString(buffer, name);
      _writeCanonicalString(buffer, argumentsKey);
    case Pattern(:var symbolId):
      buffer.write("p");
      _writeCanonicalString(buffer, symbolId?.toString() ?? value.runtimeType.toString());
    case List<Object?> items:
      buffer
        ..write("l")
        ..write(items.length)
        ..write("[");
      for (var i = 0; i < items.length; i++) {
        if (i != 0) {
          buffer.write(",");
        }
        _writeCanonicalValue(buffer, items[i]);
      }
      buffer.write("]");
    case Map<String, Object?> items:
      var entries = items.entries.toList()..sort(_compareMapEntriesByKey);
      buffer
        ..write("m")
        ..write(entries.length)
        ..write("{");
      for (var i = 0; i < entries.length; i++) {
        if (i != 0) {
          buffer.write(",");
        }
        var entry = entries[i];
        _writeCanonicalEntry(buffer, entry.key, entry.value);
      }
      buffer.write("}");
    default:
      buffer.write("o");
      _writeCanonicalString(buffer, value.toString());
  }
}

/// Normalizes a semantic value for deterministic comparison and storage.
///
/// This method recursively traverses structured values (lists, maps, captures)
/// and ensures they are in a canonical form. This is critical for the
/// parser's memoization system to correctly identify identical sub-results.
Object? normalizeSemanticValue(Object? value) {
  return switch (value) {
    CallArgumentValue argument => normalizeSemanticValue(argument.resolveData()),
    PatternClosureValue closure => closure,
    CaptureValue capture => capture,
    List<Object?> items => [for (var item in items) normalizeSemanticValue(item)],
    Map<String, Object?> items => {
      for (var entry in items.entries) entry.key: normalizeSemanticValue(entry.value),
    },
    _ => value,
  };
}

String _formatCallArgument<T>(T value) {
  // Formatting mirrors the semantic tags above so debug output and memoization
  // strings stay readable and deterministic.
  return switch (value) {
    null => "null",
    bool() || num() => "$value",
    String() => '"${value.replaceAll(r"\", r"\\").replaceAll('"', r'\"')}"',
    Rule(:var name) => name.toString(),
    CaptureValue(:var value) => value,
    ParameterCallPattern(:var name, :var argumentsKey) => "paramcall($name:$argumentsKey)",
    Pattern(:var symbolId) => symbolId?.toString() ?? value.toString(),
    _GuardLiteralValue(:var value) => _formatCallArgument(value),
    _GuardArgumentValue(:var name) => name,
    _GuardNameValue(:var name) => name,
    _GuardRuleValue() => "rule",
    List<Object?> items => _formatObjectList(items),
    Map<String, Object?> items => _formatObjectMap(items),
    _ => value.toString(),
  };
}

String _formatObjectList<T>(List<T> items) {
  // Lists are formatted recursively because nested call arguments can carry
  // structured parser data, not just scalars.
  var buffer = StringBuffer();
  buffer.write("[");
  for (var i = 0; i < items.length; i++) {
    if (i != 0) {
      buffer.write(", ");
    }
    buffer.write(_formatCallArgument(items[i]));
  }
  buffer.write("]");
  return buffer.toString();
}

/// Formats a map of objects into a deterministic string representation.
String _formatObjectMap(Map<String, Object?> items) {
  // Maps are also formatted recursively, but with stable key ordering so the
  // output does not depend on insertion order. This ensures that the same
  // semantic context always produces the same identity string.
  var entries = items.entries.toList()..sort(_compareMapEntriesByKey);
  var buffer = StringBuffer();
  buffer.write("{");
  for (var i = 0; i < entries.length; i++) {
    if (i != 0) {
      buffer.write(", ");
    }
    var entry = entries[i];
    buffer
      ..write(_formatCallArgument(entry.key))
      ..write(": ")
      ..write(_formatCallArgument(entry.value));
  }
  buffer.write("}");
  return buffer.toString();
}

/// Represents a deferred or structured value passed as a rule argument.
///
/// In Glush's parameterized rule system, arguments are not just simple scalars.
/// They can be literals, references to other parameters, patterns (for higher-order
/// rules), or even rules themselves. This hierarchy captures those possibilities
/// and provides methods for resolving them into concrete values at runtime.
sealed class CallArgumentValue {
  /// Base constructor for [CallArgumentValue].
  const CallArgumentValue();

  // Call arguments are stored in a tagged sealed hierarchy so the compiler
  // and runtime can tell literals, parser objects, and capture references apart
  // without falling back to `Object?` everywhere.

  /// Creates a [CallArgumentValue] from a raw literal.
  factory CallArgumentValue.literal(Object? value) = _CallArgumentLiteralValue;

  /// Creates a [CallArgumentValue] that refers to a parameter by [name].
  factory CallArgumentValue.reference(String name) = _CallArgumentReferenceValue;

  /// Creates a [CallArgumentValue] that passes a [rule].
  factory CallArgumentValue.rule(Rule rule) = _CallArgumentRuleValue;

  /// Creates a [CallArgumentValue] that passes a [pattern].
  factory CallArgumentValue.pattern(Pattern pattern) = _CallArgumentPatternValue;

  /// Creates a [CallArgumentValue] from a pre-captured callable thunk.
  factory CallArgumentValue.callable(PatternClosureValue callable) = _CallArgumentCallableValue;

  /// Creates a [CallArgumentValue] representing a unary expression.
  factory CallArgumentValue.unary(ExpressionUnaryOperator operator, CallArgumentValue operand) =
      _CallArgumentUnaryValue;

  /// Creates a [CallArgumentValue] representing a member access.
  factory CallArgumentValue.member(CallArgumentValue target, String member) =
      _CallArgumentMemberValue;

  /// Creates a [CallArgumentValue] representing a binary expression.
  factory CallArgumentValue.binary(
    CallArgumentValue left,
    ExpressionBinaryOperator operator,
    CallArgumentValue right,
  ) = _CallArgumentBinaryValue;

  /// Creates a [CallArgumentValue] representing an arithmetic expression.
  factory CallArgumentValue.arithmetic(
    CallArgumentValue left,
    ExpressionBinaryOperator operator,
    CallArgumentValue right,
  ) = _CallArgumentBinaryValue;

  /// Creates a [CallArgumentValue] that refers to the rule currently being executed.
  factory CallArgumentValue.currentRule() = _CallArgumentCurrentRuleValue;

  /// Creates a [CallArgumentValue] from a list of other argument values.
  factory CallArgumentValue.list(List<CallArgumentValue> values) = _CallArgumentListValue;

  /// Creates a [CallArgumentValue] from a map of other argument values.
  factory CallArgumentValue.map(Map<String, CallArgumentValue> values) = _CallArgumentMapValue;

  /// Deserializes a [CallArgumentValue] from its JSON representation.
  factory CallArgumentValue.fromJson(Map<String, Object?> json, Map<String, Rule> ruleMap) {
    var type = json["type"]! as String;
    return switch (type) {
      "lit" => CallArgumentValue.literal(json["value"]),
      "ref" => CallArgumentValue.reference(json["name"]! as String),
      "rul" => CallArgumentValue.rule(ruleMap[json["ruleName"]]!),
      "pat" => CallArgumentValue.pattern(
        Pattern.fromJson(json["pattern"]! as Map<String, Object?>, ruleMap),
      ),
      "una" => CallArgumentValue.unary(
        ExpressionUnaryOperator.values.firstWhere((e) => e.symbol == json["op"]),
        CallArgumentValue.fromJson(json["operand"]! as Map<String, Object?>, ruleMap),
      ),
      "mem" => CallArgumentValue.member(
        CallArgumentValue.fromJson(json["target"]! as Map<String, Object?>, ruleMap),
        json["member"]! as String,
      ),
      "bin" => CallArgumentValue.binary(
        CallArgumentValue.fromJson(json["left"]! as Map<String, Object?>, ruleMap),
        ExpressionBinaryOperator.values.firstWhere((e) => e.symbol == json["op"]),
        CallArgumentValue.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      ),
      "cur" => CallArgumentValue.currentRule(),
      "lis" => CallArgumentValue.list(
        (json["values"]! as List<Object?>)
            .map((v) => CallArgumentValue.fromJson(v! as Map<String, Object?>, ruleMap))
            .toList(),
      ),
      "map" => CallArgumentValue.map(
        (json["values"]! as Map<String, Object?>).map(
          (k, v) => MapEntry(k, CallArgumentValue.fromJson(v! as Map<String, Object?>, ruleMap)),
        ),
      ),
      _ => throw UnsupportedError("Unknown call argument type: $type"),
    };
  }

  /// Serializes this argument to a JSON-compatible map.
  Map<String, Object?> toJson();

  /// Resolves the argument into a concrete value using the provided [env].
  ///
  /// This is called during semantic action or guard evaluation to turn
  /// references and expressions into the actual data they represent.
  Object? resolve(GuardEnvironment env);

  /// Resolves the argument into raw data for serialization or comparison.
  Object? resolveData();

  /// Returns a human-readable string representation of the argument.
  String format();

  /// Recursively collects all rules referenced by this argument.
  void collectRules(Set<Rule> rules);

  /// Recursively collects all parameter names referred to by this argument.
  void collectReferredNames(Set<String> names);

  /// Rewrite any nested pattern values before the argument is resolved.
  ///
  /// This lets the grammar builder hoist higher-order pattern values into
  /// synthetic callable rules while preserving the rest of the argument tree.
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform);

  @override
  String toString() => format();
}

final class _CallArgumentLiteralValue extends CallArgumentValue {
  const _CallArgumentLiteralValue(this.value);

  final Object? value;

  @override
  Map<String, Object?> toJson() => {"type": "lit", "value": value};

  @override
  Object? resolve(GuardEnvironment env) => value;

  @override
  Object? resolveData() => value;

  @override
  String format() => _formatCallArgument(value);

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentReferenceValue extends CallArgumentValue {
  const _CallArgumentReferenceValue(this.name);

  final String name;

  @override
  Map<String, Object?> toJson() => {"type": "ref", "name": name};

  @override
  Object? resolve(GuardEnvironment env) => env.resolve(name) ?? this;

  @override
  Object? resolveData() => name;

  @override
  String format() => name;

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  void collectReferredNames(Set<String> names) {
    names.add(name);
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentRuleValue extends CallArgumentValue {
  const _CallArgumentRuleValue(this.rule);

  final Rule rule;

  @override
  Map<String, Object?> toJson() => {"type": "rul", "ruleName": rule.name};

  @override
  Object? resolve(GuardEnvironment env) => rule;

  @override
  Object? resolveData() => rule;

  @override
  String format() => rule.name.toString();

  @override
  void collectRules(Set<Rule> rules) {
    rules.add(rule);
  }

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentPatternValue extends CallArgumentValue {
  const _CallArgumentPatternValue(this.pattern);

  final Pattern pattern;

  @override
  Map<String, Object?> toJson() => {"type": "pat", "pattern": pattern.toJson()};

  @override
  Object? resolve(GuardEnvironment env) => _resolvePatternValue(pattern, env);

  @override
  Object? resolveData() => pattern;

  @override
  String format() => pattern.toString();

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.pattern(transform(pattern));
}

final class _CallArgumentUnaryValue extends CallArgumentValue {
  const _CallArgumentUnaryValue(this.operator, this.operand);

  final ExpressionUnaryOperator operator;
  final CallArgumentValue operand;

  @override
  Map<String, Object?> toJson() => {
    "type": "una",
    "op": operator.symbol,
    "operand": operand.toJson(),
  };

  @override
  Object? resolve(GuardEnvironment env) {
    var value = _materializeResolvedValue(operand.resolve(env), env);
    return switch (operator) {
      ExpressionUnaryOperator.logicalNot => !_requireBool(value, "logical not"),
      ExpressionUnaryOperator.negate => -_requireNum(value, "numeric negation"),
    };
  }

  @override
  Object? resolveData() => {"op": operator.symbol, "operand": operand.resolveData()};

  @override
  String format() => "${operator.symbol}${operand.format()}";

  @override
  void collectRules(Set<Rule> rules) {
    operand.collectRules(rules);
  }

  @override
  void collectReferredNames(Set<String> names) {
    operand.collectReferredNames(names);
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.unary(operator, operand.transformPatterns(transform));
}

final class _CallArgumentMemberValue extends CallArgumentValue {
  const _CallArgumentMemberValue(this.target, this.member);

  final CallArgumentValue target;
  final String member;

  @override
  Map<String, Object?> toJson() => {"type": "mem", "target": target.toJson(), "member": member};

  @override
  Object? resolve(GuardEnvironment env) =>
      _resolveMemberValue(_materializeResolvedValue(target.resolve(env), env), member);

  @override
  Object? resolveData() => {"target": target.resolveData(), "member": member};

  @override
  String format() => "${target.format()}.$member";

  @override
  void collectRules(Set<Rule> rules) {
    target.collectRules(rules);
  }

  @override
  void collectReferredNames(Set<String> names) {
    target.collectReferredNames(names);
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.member(target.transformPatterns(transform), member);
}

final class _CallArgumentBinaryValue extends CallArgumentValue {
  const _CallArgumentBinaryValue(this.left, this.operator, this.right);

  final CallArgumentValue left;
  final ExpressionBinaryOperator operator;
  final CallArgumentValue right;

  @override
  Map<String, Object?> toJson() => {
    "type": "bin",
    "left": left.toJson(),
    "op": operator.symbol,
    "right": right.toJson(),
  };

  @override
  Object? resolve(GuardEnvironment env) {
    var leftValue = _materializeResolvedValue(left.resolve(env), env);
    if (operator == ExpressionBinaryOperator.logicalAnd) {
      return _requireBool(leftValue, "logical and") &&
          _requireBool(_materializeResolvedValue(right.resolve(env), env), "logical and");
    }

    return switch (operator) {
      ExpressionBinaryOperator.add =>
        _requireNum(leftValue, "addition") +
            _requireNum(_materializeResolvedValue(right.resolve(env), env), "addition"),
      ExpressionBinaryOperator.subtract =>
        _requireNum(leftValue, "subtraction") -
            _requireNum(_materializeResolvedValue(right.resolve(env), env), "subtraction"),
      ExpressionBinaryOperator.multiply =>
        _requireNum(leftValue, "multiplication") *
            _requireNum(_materializeResolvedValue(right.resolve(env), env), "multiplication"),
      ExpressionBinaryOperator.divide =>
        _requireNum(leftValue, "division") /
            _requireNum(_materializeResolvedValue(right.resolve(env), env), "division"),
      ExpressionBinaryOperator.modulo =>
        _requireNum(leftValue, "modulo") %
            _requireNum(_materializeResolvedValue(right.resolve(env), env), "modulo"),
      ExpressionBinaryOperator.logicalOr =>
        _requireBool(leftValue, "logical or") ||
            _requireBool(_materializeResolvedValue(right.resolve(env), env), "logical or"),
      ExpressionBinaryOperator.equals => _guardValuesEqual(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
      ),
      ExpressionBinaryOperator.notEquals => !_guardValuesEqual(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
      ),
      ExpressionBinaryOperator.lessThan => _compareNumeric(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
        (a, b) => a < b,
      ),
      ExpressionBinaryOperator.lessOrEqual => _compareNumeric(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
        (a, b) => a <= b,
      ),
      ExpressionBinaryOperator.greaterThan => _compareNumeric(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
        (a, b) => a > b,
      ),
      ExpressionBinaryOperator.greaterOrEqual => _compareNumeric(
        leftValue,
        _materializeResolvedValue(right.resolve(env), env),
        (a, b) => a >= b,
      ),
      ExpressionBinaryOperator.logicalAnd => throw StateError("unreachable"),
    };
  }

  @override
  Object? resolveData() => {
    "op": operator.symbol,
    "left": left.resolveData(),
    "right": right.resolveData(),
  };

  @override
  String format() => "(${left.format()} ${operator.symbol} ${right.format()})";

  @override
  void collectRules(Set<Rule> rules) {
    left.collectRules(rules);
    right.collectRules(rules);
  }

  @override
  void collectReferredNames(Set<String> names) {
    left.collectReferredNames(names);
    right.collectReferredNames(names);
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.binary(
        left.transformPatterns(transform),
        operator,
        right.transformPatterns(transform),
      );
}

bool _requireBool(Object? value, String operation) {
  if (value is bool) {
    return value;
  }
  throw Exception("Expected boolean value for $operation");
}

num _requireNum(Object? value, String operation) {
  if (value is num) {
    return value;
  }
  throw Exception("Expected numeric value for $operation");
}

bool _compareNumeric(Object? left, Object? right, bool Function(num, num) compare) {
  if (left is! num || right is! num) {
    throw Exception("Expected numeric values for comparison");
  }
  return compare(left, right);
}

final class _CallArgumentCallableValue extends CallArgumentValue {
  const _CallArgumentCallableValue(this.callable);

  final PatternClosureValue callable;

  @override
  Map<String, Object?> toJson() => {"type": "cal", "callable": callable.toJson()};

  @override
  Object? resolve(GuardEnvironment env) => callable;

  @override
  Object? resolveData() => callable;

  @override
  String format() => callable.toString();

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

/// Captured callable pattern value.
///
/// This keeps the callable surface explicit when semantic actions need to
/// return a higher-order parser value as ordinary data.
/// A captured callable pattern coupled with its lexical environment.
///
/// This represents a higher-order pattern (like a function) that can be passed
/// as an argument. It keeps the callable body explicit when semantic actions
/// need to return a higher-order parser value as ordinary data. This is
/// critical for implementing grammar-level generic transformations.
final class PatternClosureValue {
  /// Creates a [PatternClosureValue] wrapping a [body] and its [environment].
  const PatternClosureValue(this.body, this.environment);

  /// The pattern that will be instantiated when this closure is called.
  final Pattern body;

  /// The environment (lexical scope) captured when the closure was created.
  final GuardEnvironment environment;

  /// A unique canonical key identifying this specific closure instance.
  String get key => _patternClosureKey(body, environment);

  /// Instantiates the closure by merging new [arguments] into its environment.
  PatternClosureValue apply(Map<String, Object?> arguments) {
    if (arguments.isEmpty) {
      return this;
    }
    return PatternClosureValue(body, environment.mergeWith(arguments));
  }

  /// Serializes the closure to JSON.
  Map<String, Object?> toJson() => {
    "body": body.toJson(),
    "ruleName": environment.rule.name,
    "arguments": environment.arguments,
  };

  /// Evaluates the closure into a concrete [Pattern] in the given [currentEnvironment].
  Pattern materialize([GuardEnvironment? currentEnvironment]) {
    var merged = currentEnvironment == null ? environment : environment.merge(currentEnvironment);
    return _resolvePatternValue(body, merged);
  }

  @override
  String toString() => "closure($key)";
}

String _patternClosureKey(Pattern body, GuardEnvironment environment) {
  var buffer = StringBuffer();
  _writeCanonicalString(buffer, body.toString());
  buffer.write("|");
  _writeCanonicalString(buffer, environment.rule.name.toString());
  buffer.write("|");
  _writeCanonicalValue(buffer, environment.arguments);
  buffer.write("|");
  _writeCanonicalValue(buffer, environment.valuesKey);
  return buffer.toString();
}

Pattern _resolvePatternValue(Pattern pattern, GuardEnvironment env) {
  return switch (pattern) {
    ParameterRefPattern(:var name) => switch (env.resolve(name)) {
      Rule rule => rule.call(),
      RuleCall(:var name, :var rule, :var arguments, :var minPrecedenceLevel) => RuleCall(
        name,
        rule,
        arguments: {
          for (var entry in arguments.entries)
            entry.key: _resolveCallArgumentValue(entry.value, env),
        },
        minPrecedenceLevel: minPrecedenceLevel,
      ),
      PatternClosureValue callable => callable.materialize(env),
      Pattern pattern => pattern,
      _ => pattern,
    },
    RuleCall(:var name, :var rule, :var arguments, :var minPrecedenceLevel) => RuleCall(
      name,
      rule,
      arguments: {
        for (var entry in arguments.entries) entry.key: _resolveCallArgumentValue(entry.value, env),
      },
      minPrecedenceLevel: minPrecedenceLevel,
    ),
    ParameterCallPattern(:var name, :var arguments, :var minPrecedenceLevel) => switch (env.resolve(
      name,
    )) {
      Rule rule => RuleCall(
        rule.name.toString(),
        rule,
        arguments: {
          for (var entry in arguments.entries)
            entry.key: _resolveCallArgumentValue(entry.value, env),
        },
        minPrecedenceLevel: minPrecedenceLevel,
      ),
      RuleCall call => RuleCall(
        call.name,
        call.rule,
        arguments: {
          ...call.arguments,
          for (var entry in arguments.entries)
            entry.key: _resolveCallArgumentValue(entry.value, env),
        },
        minPrecedenceLevel: call.minPrecedenceLevel ?? minPrecedenceLevel,
      ),
      PatternClosureValue callable =>
        callable
            .apply({
              for (var entry in arguments.entries)
                entry.key: _resolveCallArgumentValue(entry.value, env).resolve(env),
            })
            .materialize(env),
      Pattern pattern => pattern,
      _ => pattern,
    },
    Seq(:var left, :var right) => Seq(
      _resolvePatternValue(left, env),
      _resolvePatternValue(right, env),
    ),
    Alt(:var left, :var right) => Alt(
      _resolvePatternValue(left, env),
      _resolvePatternValue(right, env),
    ),
    Conj(:var left, :var right) => Conj(
      _resolvePatternValue(left, env),
      _resolvePatternValue(right, env),
    ),
    And(:var pattern) => And(_resolvePatternValue(pattern, env)),
    Not(:var pattern) => Not(_resolvePatternValue(pattern, env)),
    Action(:var child, :var callback) => Action(_resolvePatternValue(child, env), callback),
    Prec(:var child, :var precedenceLevel) => Prec(
      precedenceLevel,
      _resolvePatternValue(child, env),
    ),
    Opt(:var child) => Opt(_resolvePatternValue(child, env)),
    Plus(:var child) => Plus(_resolvePatternValue(child, env)),
    Star(:var child) => Star(_resolvePatternValue(child, env)),
    Label(:var name, :var child) => Label(name, _resolvePatternValue(child, env)),
    _ => pattern,
  };
}

CallArgumentValue _resolveCallArgumentValue(CallArgumentValue value, GuardEnvironment env) {
  return switch (value) {
    _CallArgumentLiteralValue() ||
    _CallArgumentReferenceValue() ||
    _CallArgumentRuleValue() ||
    _CallArgumentCurrentRuleValue() => _callArgumentValueFromResolvedObject(value.resolve(env)),
    _CallArgumentUnaryValue(:var operator, :var operand) => _callArgumentValueFromResolvedObject(
      switch (operator) {
        ExpressionUnaryOperator.logicalNot => !_requireBool(operand.resolve(env), "logical not"),
        ExpressionUnaryOperator.negate => -_requireNum(operand.resolve(env), "numeric negation"),
      },
    ),
    _CallArgumentBinaryValue(:var left, :var operator, :var right) =>
      _callArgumentValueFromResolvedObject(switch (operator) {
        ExpressionBinaryOperator.add =>
          _requireNum(left.resolve(env), "addition") + _requireNum(right.resolve(env), "addition"),
        ExpressionBinaryOperator.subtract =>
          _requireNum(left.resolve(env), "subtraction") -
              _requireNum(right.resolve(env), "subtraction"),
        ExpressionBinaryOperator.multiply =>
          _requireNum(left.resolve(env), "multiplication") *
              _requireNum(right.resolve(env), "multiplication"),
        ExpressionBinaryOperator.divide =>
          _requireNum(left.resolve(env), "division") / _requireNum(right.resolve(env), "division"),
        ExpressionBinaryOperator.modulo =>
          _requireNum(left.resolve(env), "modulo") % _requireNum(right.resolve(env), "modulo"),
        ExpressionBinaryOperator.logicalAnd =>
          _requireBool(left.resolve(env), "logical and") &&
              _requireBool(right.resolve(env), "logical and"),
        ExpressionBinaryOperator.logicalOr =>
          _requireBool(left.resolve(env), "logical or") ||
              _requireBool(right.resolve(env), "logical or"),
        ExpressionBinaryOperator.equals => _guardValuesEqual(left.resolve(env), right.resolve(env)),
        ExpressionBinaryOperator.notEquals => !_guardValuesEqual(
          left.resolve(env),
          right.resolve(env),
        ),
        ExpressionBinaryOperator.lessThan => _compareNumeric(
          left.resolve(env),
          right.resolve(env),
          (a, b) => a < b,
        ),
        ExpressionBinaryOperator.lessOrEqual => _compareNumeric(
          left.resolve(env),
          right.resolve(env),
          (a, b) => a <= b,
        ),
        ExpressionBinaryOperator.greaterThan => _compareNumeric(
          left.resolve(env),
          right.resolve(env),
          (a, b) => a > b,
        ),
        ExpressionBinaryOperator.greaterOrEqual => _compareNumeric(
          left.resolve(env),
          right.resolve(env),
          (a, b) => a >= b,
        ),
      }),
    _CallArgumentMemberValue(:var target, :var member) => _callArgumentValueFromResolvedObject(
      _resolveMemberValue(target.resolve(env), member),
    ),
    _CallArgumentCallableValue(:var callable) => _callArgumentValueFromResolvedObject(
      callable.materialize(env),
    ),
    _CallArgumentPatternValue(:var pattern) => _callArgumentValueFromResolvedObject(
      _resolvePatternValue(pattern, env),
    ),
    _CallArgumentListValue(:var values) => CallArgumentValue.list(
      values.map((entry) => _resolveCallArgumentValue(entry, env)).toList(),
    ),
    _CallArgumentMapValue(:var values) => CallArgumentValue.map({
      for (var entry in values.entries) entry.key: _resolveCallArgumentValue(entry.value, env),
    }),
  };
}

CallArgumentValue _callArgumentValueFromResolvedObject(Object? value) {
  return switch (value) {
    CallArgumentValue argument => argument,
    null || bool() || num() || String() => CallArgumentValue.literal(value),
    Rule rule => CallArgumentValue.rule(rule),
    Pattern pattern => CallArgumentValue.pattern(pattern),
    PatternClosureValue callable => CallArgumentValue.callable(callable),
    List<Object?> items => CallArgumentValue.list(
      items.map(_callArgumentValueFromResolvedObject).toList(),
    ),
    Map<String, Object?> items => CallArgumentValue.map({
      for (var entry in items.entries) entry.key: _callArgumentValueFromResolvedObject(entry.value),
    }),
    _ => CallArgumentValue.literal(value),
  };
}

Object? _materializeResolvedValue(Object? value, GuardEnvironment env) {
  var seen = <Object>{};
  while (value is CallArgumentValue) {
    if (!seen.add(value)) {
      throw UnresolvedCallArgumentReference(value);
    }
    value = value.resolve(env);
  }
  return value;
}

final class UnresolvedCallArgumentReference implements Exception {
  const UnresolvedCallArgumentReference(this.value);

  final Object? value;

  @override
  String toString() => "Unresolved reference: $value";
}

Object? _resolveMemberValue(Object? target, String member) {
  return switch (target) {
    CaptureValue() => switch (member) {
      "length" => target.length,
      "isEmpty" => target.isEmpty,
      "isNotEmpty" => target.isNotEmpty,
      "startPosition" => target.startPosition,
      "endPosition" => target.endPosition,
      "value" => target.value,
      "text" => target.value,
      _ => throw Exception("Unsupported capture member '$member'"),
    },
    String() => switch (member) {
      "length" => target.length,
      "isEmpty" => target.isEmpty,
      "isNotEmpty" => target.isNotEmpty,
      _ => throw Exception("Unsupported string member '$member'"),
    },
    List() => switch (member) {
      "length" => target.length,
      "isEmpty" => target.isEmpty,
      "isNotEmpty" => target.isNotEmpty,
      _ => throw Exception("Unsupported list member '$member'"),
    },
    Map() => switch (member) {
      "length" => target.length,
      "isEmpty" => target.isEmpty,
      "isNotEmpty" => target.isNotEmpty,
      _ => throw Exception("Unsupported map member '$member'"),
    },
    Iterable() => switch (member) {
      "length" => target.length,
      "isEmpty" => target.isEmpty,
      "isNotEmpty" => target.isNotEmpty,
      _ => throw Exception("Unsupported iterable member '$member'"),
    },
    _ => throw Exception("Unsupported member access '$member' on ${target.runtimeType}"),
  };
}

final class _CallArgumentCurrentRuleValue extends CallArgumentValue {
  const _CallArgumentCurrentRuleValue();

  @override
  Map<String, Object?> toJson() => {"type": "cur"};

  @override
  Object? resolve(GuardEnvironment env) => env.rule;

  @override
  Object? resolveData() => null;

  @override
  String format() => "rule";

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentListValue extends CallArgumentValue {
  const _CallArgumentListValue(this.values);

  final List<CallArgumentValue> values;

  @override
  Map<String, Object?> toJson() => {
    "type": "lis",
    "values": values.map((v) => v.toJson()).toList(),
  };

  @override
  Object? resolve(GuardEnvironment env) {
    // Lists resolve element-by-element so nested references and rules can be
    // carried through as structured argument data.
    var resolved = <Object?>[];
    for (var value in values) {
      resolved.add(value.resolve(env));
    }
    return resolved;
  }

  @override
  Object? resolveData() => values.map((value) => value.resolveData()).toList();

  @override
  String format() {
    // The string form stays deterministic so memoization keys remain stable.
    var parts = values.map((v) => v.format());
    return "[${parts.join(', ')}]";
  }

  @override
  void collectRules(Set<Rule> rules) {
    for (var value in values) {
      value.collectRules(rules);
    }
  }

  @override
  void collectReferredNames(Set<String> names) {
    for (var value in values) {
      value.collectReferredNames(names);
    }
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.list(values.map((value) => value.transformPatterns(transform)).toList());
}

final class _CallArgumentMapValue extends CallArgumentValue {
  const _CallArgumentMapValue(this.values);

  final Map<String, CallArgumentValue> values;

  @override
  Map<String, Object?> toJson() => {
    "type": "map",
    "values": values.map((k, v) => MapEntry(k, v.toJson())),
  };

  @override
  Object? resolve(GuardEnvironment env) {
    // Maps resolve key-by-key so nested values stay readable to the guard
    // environment while preserving the original structure.
    var resolved = <String, Object?>{};
    for (var entry in values.entries) {
      resolved[entry.key] = entry.value.resolve(env);
    }
    return Map<String, Object?>.unmodifiable(resolved);
  }

  @override
  Object? resolveData() => Map<String, Object?>.unmodifiable({
    for (var entry in values.entries) entry.key: entry.value.resolveData(),
  });

  @override
  String format() {
    // Key order matters for memoization, so the formatted map is stable and
    // sorted rather than depending on insertion order.
    var parts = values.entries.map((e) => "${e.key}: ${e.value.format()}");
    return "{${parts.join(', ')}}";
  }

  @override
  void collectRules(Set<Rule> rules) {
    for (var value in values.values) {
      value.collectRules(rules);
    }
  }

  @override
  void collectReferredNames(Set<String> names) {
    for (var value in values.values) {
      value.collectReferredNames(names);
    }
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.map({
        for (var entry in values.entries) entry.key: entry.value.transformPatterns(transform),
      });
}

GuardEnvironment _mergeGuardEnvironments(GuardEnvironment base, GuardEnvironment override) {
  return GuardEnvironment(
    rule: override.rule,
    marks: override._marksForest,
    arguments: {...base.arguments, ...override.arguments},
    values: {...base.values, ...override.values},
    valuesKey: MergedCallArgumentsKey(base.valuesKey, override.valuesKey),
    valueResolver: override.valueResolver ?? base.valueResolver,
    captureResolver: override.captureResolver ?? base.captureResolver,
    rulesByName: {...base.rulesByName, ...override.rulesByName},
  );
}

/// Runtime environment exposed to data-driven guard expressions.
///
/// This environment acts as a bridge between the parser's internal state (marks,
/// rules, current position) and the semantic expressions defined in the grammar.
/// It provides scoped resolution for parameters, captures, and built-in keywords
/// like 'rule' or 'capture'.
final class GuardEnvironment {
  /// Creates a [GuardEnvironment] with the provided execution context.
  GuardEnvironment({
    required this.rule,
    LazyGlushList<Mark> marks = const LazyGlushList<Mark>.empty(),
    this.arguments = const <String, Object?>{},
    this.values = const <String, Object?>{},
    CallArgumentsKey? valuesKey,
    this.valueResolver,
    this.captureResolver,
    this.rulesByName = const <RuleName, Rule>{},
  }) : _marksForest = marks,
       valuesKey =
           valuesKey ??
           (values.isEmpty
               ? const EmptyCallArgumentsKey()
               : StringCallArgumentsKey(_formatObjectMap(values)));

  /// The rule currently being evaluated.
  final Rule rule;

  /// The internal forest of marks available for capture resolution.
  final LazyGlushList<Mark> _marksForest;

  /// Parameter arguments passed explicitly to the rule.
  final Map<String, Object?> arguments;

  /// Explicit local values injected into the environment.
  final Map<String, Object?> values;

  /// A canonical key identifying the set of values in this environment.
  final CallArgumentsKey valuesKey;

  /// An optional resolver for looking up arbitrary names in a parent scope.
  final Object? Function(String name)? valueResolver;

  /// An optional resolver for extracting [CaptureValue]s from the mark forest.
  final CaptureValue? Function(LazyGlushList<Mark>, String)? captureResolver;

  /// A map of all rules currently known to the grammar, used for cross-references.
  final Map<RuleName, Rule> rulesByName;

  final Map<String, CaptureValue?> _captureCache = {};

  CaptureValue? _resolveCapture(String name) {
    if (_captureCache.containsKey(name)) {
      return _captureCache[name];
    }

    var capture = captureResolver?.call(_marksForest, name);
    _captureCache[name] = capture;
    return capture;
  }

  /// Resolves a [name] within the environment's tiered scopes.
  ///
  /// The resolution follows this order:
  /// 1. Rule parameters (arguments).
  /// 2. Explicit runtime values or external resolver overrides.
  /// 3. Built-in keywords ('rule', 'capture').
  /// 4. Named captures from the mark forest.
  /// 5. Global rule references by name.
  Object? resolve(String name) {
    // Stage 1: Parameters (arguments passed to the rule)
    if (arguments.containsKey(name)) {
      return arguments[name];
    }

    // Stage 2: Explicit runtime values (captures, resolver overrides)
    var explicit = values[name] ?? valueResolver?.call(name);
    if (explicit != null) {
      return explicit;
    }

    // Stage 3: Built-in keywords
    if (name == "rule") {
      return rule;
    }
    if (name == "capture") {
      return _captureCache.values.lastOrNull ?? _resolveCapture(name);
    }

    // Stage 4: Captures and rule references
    return _resolveCapture(name) ?? rulesByName[RuleName(name)];
  }

  GuardEnvironment mergeWith(Map<String, Object?> additions) {
    if (additions.isEmpty) {
      return this;
    }
    return GuardEnvironment(
      rule: rule,
      marks: _marksForest,
      arguments: {...arguments, ...additions},
      values: values,
      valuesKey: valuesKey,
      valueResolver: valueResolver,
      captureResolver: captureResolver,
      rulesByName: rulesByName,
    );
  }

  GuardEnvironment merge(GuardEnvironment other) => _mergeGuardEnvironments(this, other);
}

/// Represents a value that can be retrieved and evaluated within a guard expression.
///
/// Guard values differentiate between raw literals, named arguments, and
/// structural references like rule identities.
sealed class GuardValue {
  /// Base constructor for [GuardValue].
  const GuardValue();

  /// Deserializes a [GuardValue] from JSON.
  factory GuardValue.fromJson(Map<String, Object?> json) {
    var type = json["type"]! as String;
    return switch (type) {
      "gvl" => GuardValue.literal(json["value"]),
      "gva" => GuardValue.argument(json["name"]! as String),
      "gvn" => GuardValue.name(json["name"]! as String),
      "gvr" => GuardValue.rule(),
      _ => throw FormatException("Unknown guard value type: $type"),
    };
  }

  // Guard values are typed separately from call arguments so expression
  // evaluation can tell runtime data, rule references, and the special `rule`
  // symbol apart.

  /// Creates a [GuardValue] from a raw literal.
  factory GuardValue.literal(Object? value) = _GuardLiteralValue;

  /// Creates a [GuardValue] that refers to a named argument.
  factory GuardValue.argument(String name) = _GuardArgumentValue;

  /// Creates a [GuardValue] that refers to a named capture or rule.
  factory GuardValue.name(String name) = _GuardNameValue;

  /// Creates a [GuardValue] representing the special 'rule' keyword.
  factory GuardValue.rule() = _GuardRuleValue;

  /// Evaluates this value within the given [env].
  Object? evaluate(GuardEnvironment env);

  /// Recursively collects all names referenced by this value.
  void collectReferredNames(Set<String> names);

  /// Serializes the value to JSON.
  Map<String, Object?> toJson();

  /// Helper to create an equality comparison guard.
  GuardExpr eq(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.eq);

  /// Helper to create a non-equality comparison guard.
  GuardExpr ne(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.ne);

  /// Helper to create a greater-than comparison guard.
  GuardExpr gt(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.gt);

  /// Helper to create a greater-than-or-equal comparison guard.
  GuardExpr gte(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.gte);

  /// Helper to create a less-than comparison guard.
  GuardExpr lt(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.lt);

  /// Helper to create a less-than-or-equal comparison guard.
  GuardExpr lte(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.lte);
}

/// Represents a boolean expression used to guard a parsing path.
///
/// Guard expressions form a small AST that can be evaluated during the parse
/// to determine if a specific transition is valid based on semantic context
/// and prior results.
sealed class GuardExpr {
  /// Base constructor for [GuardExpr].
  const GuardExpr();

  /// Deserializes a [GuardExpr] from JSON.
  factory GuardExpr.fromJson(Map<String, Object?> json, Map<String, Rule> ruleMap) {
    var type = json["type"]! as String;
    return switch (type) {
      "gel" => GuardExpr.literal(json["value"]! as bool),
      "gev" => GuardExpr.value(GuardValue.fromJson(json["value"]! as Map<String, Object?>)),
      "gee" => GuardExpr.expression(
        CallArgumentValue.fromJson(json["value"]! as Map<String, Object?>, ruleMap),
      ),
      "gec" => _GuardComparison(
        GuardValue.fromJson(json["left"]! as Map<String, Object?>),
        GuardValue.fromJson(json["right"]! as Map<String, Object?>),
        _GuardComparisonKind.values.byName(json["kind"]! as String),
      ),
      "gea" =>
        GuardExpr.fromJson(json["left"]! as Map<String, Object?>, ruleMap) &
            GuardExpr.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      "geo" =>
        GuardExpr.fromJson(json["left"]! as Map<String, Object?>, ruleMap) |
            GuardExpr.fromJson(json["right"]! as Map<String, Object?>, ruleMap),
      "gen" => GuardNot(GuardExpr.fromJson(json["child"]! as Map<String, Object?>, ruleMap)),
      _ => throw FormatException("Unknown guard expr type: $type"),
    };
  }

  // Guard expressions are a tiny boolean AST that the runtime can evaluate
  // directly inside the state machine.

  /// Creates a [GuardExpr] from a constant boolean value.
  factory GuardExpr.literal(bool value) = _GuardLiteralExpr;

  /// Creates a [GuardExpr] that evaluates a single [GuardValue].
  factory GuardExpr.value(GuardValue value) = GuardValueExpr;

  /// Creates a [GuardExpr] that evaluates a complex [CallArgumentValue].
  factory GuardExpr.expression(CallArgumentValue value) = _GuardExpressionExpr;

  /// Evaluates the expression within the given [env].
  bool evaluate(GuardEnvironment env);

  /// Recursively collects all names referenced by this expression.
  void collectReferredNames(Set<String> names);

  /// Serializes the expression to JSON.
  Map<String, Object?> toJson();

  /// Combines this expression with another using logical AND.
  GuardExpr and(GuardExpr other) => GuardAnd(this, other);

  /// Combines this expression with another using logical OR.
  GuardExpr or(GuardExpr other) => GuardOr(this, other);

  /// Negates this expression.
  GuardExpr not() => GuardNot(this);

  /// Operator alias for [and].
  GuardExpr operator &(GuardExpr other) => and(other);

  /// Operator alias for [or].
  GuardExpr operator |(GuardExpr other) => or(other);

  /// Operator alias for [not].
  GuardExpr operator ~() => not();
}

GuardValue _coerceGuardValue(Object? value) {
  return value is GuardValue ? value : GuardValue.literal(value);
}

final class _GuardLiteralValue extends GuardValue {
  const _GuardLiteralValue(this.value);

  final Object? value;

  @override
  Object? evaluate(GuardEnvironment env) => value;

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  Map<String, Object?> toJson() => {"type": "gvl", "value": value};
}

final class _GuardArgumentValue extends GuardValue {
  const _GuardArgumentValue(this.name);

  final String name;

  @override
  Object? evaluate(GuardEnvironment env) => env.resolve(name);

  @override
  void collectReferredNames(Set<String> names) {
    names.add(name);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gva", "name": name};
}

final class _GuardNameValue extends GuardValue {
  const _GuardNameValue(this.name);

  final String name;

  @override
  Object? evaluate(GuardEnvironment env) => env.resolve(name);

  @override
  void collectReferredNames(Set<String> names) {
    names.add(name);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gvn", "name": name};
}

final class _GuardRuleValue extends GuardValue {
  const _GuardRuleValue();

  @override
  Object? evaluate(GuardEnvironment env) => env.rule;

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  Map<String, Object?> toJson() => {"type": "gvr"};
}

final class _GuardLiteralExpr extends GuardExpr {
  const _GuardLiteralExpr(this.value);

  final bool value;

  @override
  bool evaluate(GuardEnvironment env) => value;

  @override
  void collectReferredNames(Set<String> names) {}

  @override
  Map<String, Object?> toJson() => {"type": "gel", "value": value};
}

enum _GuardComparisonKind { eq, ne, gt, gte, lt, lte }

final class _GuardComparison extends GuardExpr {
  const _GuardComparison(this.left, this.right, this.kind);

  final GuardValue left;
  final GuardValue right;
  final _GuardComparisonKind kind;

  @override
  bool evaluate(GuardEnvironment env) {
    var leftValue = left.evaluate(env);
    var rightValue = right.evaluate(env);
    var comparison = _compareNumbers(leftValue, rightValue);
    return switch (kind) {
      _GuardComparisonKind.eq => _guardValuesEqual(leftValue, rightValue),
      _GuardComparisonKind.ne => !_guardValuesEqual(leftValue, rightValue),
      _GuardComparisonKind.gt => comparison != null && comparison > 0,
      _GuardComparisonKind.gte => comparison != null && comparison >= 0,
      _GuardComparisonKind.lt => comparison != null && comparison < 0,
      _GuardComparisonKind.lte => comparison != null && comparison <= 0,
    };
  }

  @override
  void collectReferredNames(Set<String> names) {
    left.collectReferredNames(names);
    right.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {
    "type": "gec",
    "left": left.toJson(),
    "right": right.toJson(),
    "kind": kind.name,
  };
}

final class GuardAnd extends GuardExpr {
  const GuardAnd(this.left, this.right);

  final GuardExpr left;
  final GuardExpr right;

  @override
  bool evaluate(GuardEnvironment env) => left.evaluate(env) && right.evaluate(env);

  @override
  void collectReferredNames(Set<String> names) {
    left.collectReferredNames(names);
    right.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gea", "left": left.toJson(), "right": right.toJson()};
}

final class GuardOr extends GuardExpr {
  const GuardOr(this.left, this.right);

  final GuardExpr left;
  final GuardExpr right;

  @override
  bool evaluate(GuardEnvironment env) => left.evaluate(env) || right.evaluate(env);

  @override
  void collectReferredNames(Set<String> names) {
    left.collectReferredNames(names);
    right.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {"type": "geo", "left": left.toJson(), "right": right.toJson()};
}

final class GuardNot extends GuardExpr {
  const GuardNot(this.child);

  final GuardExpr child;

  @override
  bool evaluate(GuardEnvironment env) => !child.evaluate(env);

  @override
  void collectReferredNames(Set<String> names) {
    child.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gen", "child": child.toJson()};
}

final class GuardValueExpr extends GuardExpr {
  const GuardValueExpr(this.value);

  final GuardValue value;

  @override
  bool evaluate(GuardEnvironment env) {
    var evaluated = value.evaluate(env);
    return switch (evaluated) {
      bool value => value,
      null => false,
      _ => true,
    };
  }

  @override
  void collectReferredNames(Set<String> names) {
    value.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gev", "value": value.toJson()};
}

final class _GuardExpressionExpr extends GuardExpr {
  const _GuardExpressionExpr(this.value);

  final CallArgumentValue value;

  @override
  bool evaluate(GuardEnvironment env) {
    Object? evaluated;
    try {
      evaluated = value.resolve(env);
    } on UnresolvedCallArgumentReference {
      // Speculative branches can reach a guard before its capture inputs are
      // available. Treat that as a failed branch rather than aborting the parse.
      return false;
    }
    if (evaluated is bool) {
      return evaluated;
    }
    throw Exception("if guard must evaluate to a boolean");
  }

  @override
  void collectReferredNames(Set<String> names) {
    value.collectReferredNames(names);
  }

  @override
  Map<String, Object?> toJson() => {"type": "gee", "value": value.toJson()};
}

int? _compareNumbers(Object? left, Object? right) {
  if (left is! num || right is! num) {
    return null;
  }
  return left.compareTo(right);
}

bool _guardValuesEqual(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is CaptureValue && right is CaptureValue) {
    return left.value == right.value;
  }
  if (left is CaptureValue && right is String) {
    return left.value == right;
  }
  if (left is String && right is CaptureValue) {
    return left == right.value;
  }
  if (left is num && right is num) {
    return left == right;
  }
  if (left is String && right is String) {
    return left == right;
  }
  if (left is bool && right is bool) {
    return left == right;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (var entry in left.entries) {
      if (!right.containsKey(entry.key)) {
        return false;
      }
      if (!_guardValuesEqual(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is Iterable && right is Iterable) {
    var leftIterator = left.iterator;
    var rightIterator = right.iterator;
    while (true) {
      var leftHasNext = leftIterator.moveNext();
      var rightHasNext = rightIterator.moveNext();
      if (leftHasNext != rightHasNext) {
        return false;
      }
      if (!leftHasNext) {
        return true;
      }
      if (!_guardValuesEqual(leftIterator.current, rightIterator.current)) {
        return false;
      }
    }
  }
  return left == right;
}

/// Represents a captured result from a labeled mark span.
///
/// When a part of the input is matched by a [Label] pattern, the parser
/// extracts the consumed text and its boundaries into a [CaptureValue].
/// This value is then available in semantic actions and guards to perform
/// context-sensitive logic or to build an AST.
final class CaptureValue {
  /// Creates a [CaptureValue] with the specified span and content.
  const CaptureValue(this.startPosition, this.endPosition, this.value);

  /// The absolute starting position of the capture in the input stream.
  final int startPosition;

  /// The absolute ending position of the capture in the input stream.
  final int endPosition;

  /// The raw string content of the capture.
  final String value;

  /// The number of characters consumed by this capture.
  int get length => endPosition - startPosition;

  /// Whether the capture matched an empty string (epsilon).
  bool get isEmpty => length == 0;

  /// Whether the capture matched at least one character.
  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => value;
}

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
        .reduce((acc, curr) => acc >> curr)
        .withAction((span, _) => span);

    return result;
  }

  /// Deserializes a [Pattern] from its JSON representation.
  factory Pattern.fromJson(Map<String, Object?> json, Map<String, Rule> ruleMap) {
    var type = json["type"]! as String;
    Pattern pattern = switch (type) {
      "tok" => Token.fromJson(json),
      "mar" => Marker(json["name"]! as String),
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
        arguments: {
          if (json["arguments"] case Map<String, Object?> map)
            for (var MapEntry(key: k, value: v) in map.entries)
              k: CallArgumentValue.fromJson(v! as Map<String, Object?>, ruleMap),
        },
        minPrecedenceLevel: json["minPrecedenceLevel"] as int?,
      ),
      "par" => ParameterRefPattern(json["name"]! as String),
      "pac" => ParameterCallPattern(
        json["name"]! as String,
        arguments: {
          if (json["arguments"] case Map<String, Object?> map)
            for (var MapEntry(key: k, value: v) in map.entries)
              k: CallArgumentValue.fromJson(v! as Map<String, Object?>, ruleMap),
        },
        minPrecedenceLevel: json["minPrecedenceLevel"] as int?,
      ),
      "act" => Action(
        Pattern.fromJson(json["child"]! as Map<String, Object?>, ruleMap),
        (span, results) => throw UnsupportedError("Cannot deserialize action callback"),
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

  /// Attaches a semantic [callback] to this pattern.
  ///
  /// The callback receives the matched input span and the results of any
  /// child semantic actions.
  Action<T> withAction<T>(T Function(String span, List<Object?> childResults) callback) {
    return Action<T>(this, callback);
  }

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
      Marker() => "mar",
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
      ParameterRefPattern() => "par",
      ParameterCallPattern() => "pac",
      Action() => "act",
      Prec() => "pre",
      Opt() => "opt",
      Plus() => "plu",
      Star() => "sta",
      Label() => "lab",
      LabelStart() => "las",
      LabelEnd() => "lae",
      IfCond() => "if",
      Retreat() => "ret",
    };
  }

  /// DSL helper for an optional variant of this pattern.
  Alt maybe() => this | Eps();

  /// DSL helper for positive lookahead (AND predicate).
  And and() => And(this);

  /// DSL helper for negative lookahead (NOT predicate).
  Not not() => Not(this);

  /// DSL helper for an inline semantic guard.
  IfCond when(GuardExpr condition) => IfCond(condition, this);
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

/// A pattern that emits a semantic marker when matched.
///
/// Markers are zero-width patterns that are used to track the progress of the
/// parse or to insert custom semantic indicators into the mark forest.
class Marker extends Pattern {
  /// Creates a [Marker] with the specified [name].
  Marker(this.name);

  /// The name of the marker.
  final String name;

  @override
  Map<String, Object?> toJson() => {"type": "mar", "name": name};

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

/// A pattern that matches a child pattern only if a semantic condition is met.
///
/// [IfCond] provides fine-grained control over parsing paths by evaluating
/// a [condition] expression against the current [GuardEnvironment]. If the
/// condition is false, the branch is immediately pruned.
class IfCond extends Pattern {
  /// Creates an [IfCond] wrapping [p] with a [condition].
  IfCond(this.condition, Pattern p) : pattern = p.consume();

  /// The semantic condition to evaluate.
  final GuardExpr condition;

  /// The child pattern to match if the condition holds.
  Pattern pattern;

  @override
  IfCond copy() => IfCond(condition, pattern.copy());

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // Guards require semantic evaluation and are extracted as rules during normalization.
    pattern.calculateEmpty(emptyRules);
    setEmpty(false);
    return false;
  }

  @override
  bool isStatic() => pattern.isStatic();

  @override
  Set<Pattern> firstSet() => pattern.firstSet();

  @override
  Set<Pattern> lastSet() => pattern.lastSet();

  @override
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* pattern.eachPair();
  }

  @override
  void collectRules(Set<Rule> rules) {
    pattern.collectRules(rules);
  }

  @override
  Map<String, Object?> toJson() => {
    "type": "if",
    "condition": condition.toJson(),
    "child": pattern.toJson(),
  };

  @override
  String toString() => "if($condition, $pattern)";
}

/// Top-level helper for inline guards.
IfCond if_(GuardExpr condition, Pattern pattern) => IfCond(condition, pattern);

extension type RuleName(String symbol) {}

/// A high-level grammar rule that encapsulates a parsing fragment.
///
/// Rules are the primary unit of reuse in a grammar. They can be recursive,
/// parameterized, and guarded. A rule has a [name] and a [body] (the pattern it
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

  /// An optional guard that must pass for this rule to be considered valid.
  GuardExpr? guard;

  /// The rule that 'owns' or defines this rule if it was generated (e.g., a guard rule).
  Rule? guardOwner;

  /// Creates a [RuleCall] to this rule with the given [arguments] and [minPrecedenceLevel].
  RuleCall call({Map<String, CallArgumentValue> arguments = const {}, int? minPrecedenceLevel}) {
    var name = "${this.name}_${calls.length}";
    var call = RuleCall(name, this, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);
    calls.add(call);
    return call;
  }

  /// Attaches a [guard] expression to this rule.
  Rule guardedBy(GuardExpr guard) {
    this.guard = guard;
    return this;
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

    if (guard != null) {
      // Guarded rules are never statically empty because they require
      // runtime precondition checks before the empty path can be followed.
      setEmpty(false);
      return false;
    }
    setEmpty(bodyEmpty);
    return bodyEmpty;
  }

  @override
  Rule copy() {
    var copy = Rule(name.symbol, _code);
    copy.guard = guard;
    copy.guardOwner = guardOwner;
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
/// [arguments] for parameters and a [minPrecedenceLevel] for disambiguation.
class RuleCall extends Pattern {
  /// Creates a [RuleCall] to the specified [rule] with the given parameters.
  RuleCall(
    this.name,
    this.rule, {
    Map<String, CallArgumentValue> arguments = const {},
    this.minPrecedenceLevel,
  }) : arguments = Map<String, CallArgumentValue>.unmodifiable(arguments),
       argumentsKey = _callArgumentSourceKey(arguments),
       _argumentNames = _sortedArgumentNames(arguments.keys, const []);

  /// A local name for this call instance.
  final String name;

  /// The rule being called.
  final Rule rule;

  /// The arguments passed to the rule's parameters.
  final Map<String, CallArgumentValue> arguments;

  /// A pre-computed key representing the static structure of the arguments.
  final String argumentsKey;
  final List<String> _argumentNames;

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
    "arguments": arguments.map((k, v) => MapEntry(k, v.toJson())),
    "minPrecedenceLevel": minPrecedenceLevel,
    "symbolId": symbolId,
  };

  @override
  RuleCall copy() =>
      RuleCall(name, rule, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);

  /// Resolves the call's arguments into concrete objects for the runtime.
  ///
  /// Returns both the resolved arguments map and a unique [CallArgumentsKey]
  /// for memoizing the call's results.
  ({Map<String, Object?> arguments, CallArgumentsKey key}) resolveArgumentsAndKey(
    GuardEnvironment env,
  ) {
    // Resolve the typed call-argument model once at the call boundary, then
    // hand the state machine a plain resolved map and a memoization key.
    var resolved = <String, Object?>{};
    var resolvedValues = <Object?>[];

    for (var i = 0; i < _argumentNames.length; i++) {
      var name = _argumentNames[i];
      var value = arguments[name]!.resolve(env);
      resolved[name] = value;
      resolvedValues.add(value);
    }

    var key = switch (resolvedValues.length) {
      0 => StringCallArgumentsKey(argumentsKey),
      _ => CompositeCallArgumentsKey(List<Object?>.unmodifiable(resolvedValues)),
    };

    return (arguments: Map<String, Object?>.unmodifiable(resolved), key: key);
  }

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    if (rule.guard != null) {
      // Guarded rules are never statically empty because they require
      // runtime precondition checks before the empty path can be followed.
      setEmpty(false);
      return false;
    }
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
    for (var arg in arguments.values) {
      arg.collectRules(rules);
    }
  }

  @override
  String toString() {
    var parts = <String>[];
    parts.addAll(
      arguments.entries.map(
        (entry) => "${_formatCallArgument(entry.key)}: ${entry.value.format()}",
      ),
    );
    var args = parts.isEmpty ? "" : "(${parts.join(', ')})";
    var prec = minPrecedenceLevel != null ? "^$minPrecedenceLevel" : "";
    return "<$name$args$prec>";
  }
}

/// A pattern that references a rule parameter.
///
/// This is used in rule bodies to stand in for a pattern that will be passed
/// in at runtime. For example, in `repeat(content)`, `content` is a
/// [ParameterRefPattern].
class ParameterRefPattern extends Pattern {
  /// Creates a [ParameterRefPattern] with the given [name].
  ParameterRefPattern(this.name);

  /// The name of the parameter being referenced.
  final String name;

  @override
  ParameterRefPattern copy() => ParameterRefPattern(name);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // A parameter reference is runtime-dependent; keep it conservative.
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
  void collectRules(Set<Rule> rules) {}

  @override
  Map<String, Object?> toJson() => {"type": "par", "name": name};

  @override
  String toString() => "param($name)";
}

/// A pattern that calls a rule parameter with its own arguments.
///
/// This supports higher-order rules where a parameter itself takes parameters.
/// For example, if `wrapper` is a parameter, `wrapper(inner: atom)` is a
/// [ParameterCallPattern].
class ParameterCallPattern extends Pattern {
  /// Creates a [ParameterCallPattern] for parameter [name].
  ParameterCallPattern(
    this.name, {
    Map<String, CallArgumentValue> arguments = const {},
    this.minPrecedenceLevel,
  }) : arguments = Map<String, CallArgumentValue>.unmodifiable(arguments),
       argumentsKey = _callArgumentSourceKey(arguments);

  /// The name of the parameter being called.
  final String name;

  /// The arguments passed to the parameter's own parameters.
  final Map<String, CallArgumentValue> arguments;

  /// A pre-computed key representing the static structure of the arguments.
  final String argumentsKey;

  /// Optional precedence filter for the parameter call.
  final int? minPrecedenceLevel;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    "name": name,
    "arguments": arguments.map((k, v) => MapEntry(k, v.toJson())),
    "minPrecedenceLevel": minPrecedenceLevel,
  };

  @override
  ParameterCallPattern copy() =>
      ParameterCallPattern(name, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);

  @override
  bool calculateEmpty(Set<Rule> emptyRules) {
    // Higher-order calls are runtime-dependent.
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
  void collectRules(Set<Rule> rules) {
    for (var arg in arguments.values) {
      arg.collectRules(rules);
    }
  }

  @override
  String toString() {
    var parts = <String>[];
    parts.addAll(
      arguments.entries.map(
        (entry) => "${_formatCallArgument(entry.key)}: ${entry.value.format()}",
      ),
    );
    var args = parts.isEmpty ? "" : "(${parts.join(', ')})";
    var prec = minPrecedenceLevel != null ? "^$minPrecedenceLevel" : "";
    return "param($name$args$prec)";
  }
}

/// A pattern that executes a semantic callback when its child pattern matches.
///
/// [Action] is used to transform the raw parse forest into a semantic domain
/// model. The callback is executed during the structure evaluation phase,
/// receiving the matched span and the list of child results.
class Action<T> extends Pattern {
  /// Creates an [Action] wrapping [child] with a [callback].
  Action(this.child, this.callback);

  /// The child pattern that triggers the action.
  Pattern child;

  /// The callback to execute when the child matches.
  final T Function(String span, List<Object?> childResults) callback;

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
  Map<String, Object?> toJson() => {"type": "act", "child": child.toJson()};

  @override
  String toString() => "action($child)";
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
/// Labeled patterns are used to extract specific parts of a match into
/// the [GuardEnvironment] for semantic predicates or actions.
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
