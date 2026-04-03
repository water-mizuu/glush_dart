// ignore_for_file: avoid_positional_boolean_parameters, use_to_and_as_if_applicable

/// Pattern system for grammar definition
library glush.patterns;

import "package:glush/src/compiler/format.dart";
import "package:glush/src/core/errors.dart";
import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/profiling.dart";
import "package:meta/meta.dart";

@immutable
sealed class CallArgumentsKey {
  const CallArgumentsKey();
}

final class StringCallArgumentsKey extends CallArgumentsKey {
  const StringCallArgumentsKey(this.key);
  final String key;

  @override
  bool operator ==(Object other) => other is StringCallArgumentsKey && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

final class EmptyCallArgumentsKey extends CallArgumentsKey {
  const EmptyCallArgumentsKey();

  @override
  bool operator ==(Object other) => other is EmptyCallArgumentsKey;

  @override
  int get hashCode => (EmptyCallArgumentsKey).hashCode;

  @override
  String toString() => "";
}

final class GuardValuesKey extends CallArgumentsKey {
  const GuardValuesKey({
    required this.captureSignature,
    required this.ruleName,
    required this.position,
    required this.callStart,
    required this.minPrecedenceLevel,
    required this.precedenceLevel,
  });

  final String captureSignature;
  final String ruleName;
  final int position;
  final int callStart;
  final int? minPrecedenceLevel;
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

final class CompositeCallArgumentsKey extends CallArgumentsKey {
  const CompositeCallArgumentsKey(this.values);
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

final class MergedCallArgumentsKey extends CallArgumentsKey {
  const MergedCallArgumentsKey(this.left, this.right);
  final CallArgumentsKey? left;
  final CallArgumentsKey? right;

  @override
  bool operator ==(Object other) =>
      other is MergedCallArgumentsKey && other.left == left && other.right == right;

  @override
  int get hashCode => Object.hash(left, right);
}

extension type const PatternSymbol(String symbol) {}

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
      _writeCanonicalString(buffer, name.symbol);
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
      _writeCanonicalString(buffer, symbolId?.symbol ?? value.runtimeType.toString());
    case List<dynamic> items:
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

Object? normalizeSemanticValue(Object? value) {
  return switch (value) {
    CallArgumentValue argument => normalizeSemanticValue(argument.resolveData()),
    PatternClosureValue closure => closure,
    CaptureValue capture => capture,
    List<dynamic> items => [for (var item in items) normalizeSemanticValue(item)],
    Map<String, Object?> items => {
      for (var entry in items.entries) entry.key: normalizeSemanticValue(entry.value),
    },
    _ => value,
  };
}

String _formatCallArgument(Object? value) {
  // Formatting mirrors the semantic tags above so debug output and memoization
  // strings stay readable and deterministic.
  return switch (value) {
    null => "null",
    bool() || num() => "$value",
    String() => '"${value.replaceAll(r"\", r"\\").replaceAll('"', r'\"')}"',
    Rule(:var name) => name.symbol,
    CaptureValue(:var value) => value,
    ParameterCallPattern(:var name, :var argumentsKey) => "paramcall($name:$argumentsKey)",
    Pattern(:var symbolId) => symbolId?.symbol ?? value.toString(),
    _GuardLiteralValue(:var value) => _formatCallArgument(value),
    _GuardArgumentValue(:var name) => name,
    _GuardNameValue(:var name) => name,
    _GuardRuleValue() => "rule",
    List<dynamic> items => _formatObjectList(items),
    Map<String, Object?> items => _formatObjectMap(items),
    _ => value.toString(),
  };
}

String _formatObjectList(List<dynamic> items) {
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

String _formatObjectMap(Map<String, Object?> items) {
  // Maps are also formatted recursively, but with stable key ordering so the
  // output does not depend on insertion order.
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

sealed class CallArgumentValue {
  const CallArgumentValue();

  // Call arguments are stored in a tagged sealed hierarchy so the compiler
  // and runtime can tell literals, parser objects, and capture references apart
  // without falling back to `Object?` everywhere.
  factory CallArgumentValue.literal(Object? value) = _CallArgumentLiteralValue;
  factory CallArgumentValue.reference(String name) = _CallArgumentReferenceValue;
  factory CallArgumentValue.rule(Rule rule) = _CallArgumentRuleValue;
  factory CallArgumentValue.pattern(Pattern pattern) = _CallArgumentPatternValue;
  factory CallArgumentValue.callable(PatternClosureValue callable) = _CallArgumentCallableValue;
  factory CallArgumentValue.unary(ExpressionUnaryOperator operator, CallArgumentValue operand) =
      _CallArgumentUnaryValue;
  factory CallArgumentValue.member(CallArgumentValue target, String member) =
      _CallArgumentMemberValue;
  factory CallArgumentValue.binary(
    CallArgumentValue left,
    ExpressionBinaryOperator operator,
    CallArgumentValue right,
  ) = _CallArgumentBinaryValue;
  factory CallArgumentValue.arithmetic(
    CallArgumentValue left,
    ExpressionBinaryOperator operator,
    CallArgumentValue right,
  ) = _CallArgumentBinaryValue;
  factory CallArgumentValue.currentRule() = _CallArgumentCurrentRuleValue;
  factory CallArgumentValue.list(List<CallArgumentValue> values) = _CallArgumentListValue;
  factory CallArgumentValue.map(Map<String, CallArgumentValue> values) = _CallArgumentMapValue;

  Object? resolve(GuardEnvironment env);
  Object? resolveData();
  String format();

  void collectRules(Set<Rule> rules);

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
  Object? resolve(GuardEnvironment env) => value;

  @override
  Object? resolveData() => value;

  @override
  String format() => _formatCallArgument(value);

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentReferenceValue extends CallArgumentValue {
  const _CallArgumentReferenceValue(this.name);

  final String name;

  @override
  Object? resolve(GuardEnvironment env) => env.resolve(name) ?? this;

  @override
  Object? resolveData() => name;

  @override
  String format() => name;

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentRuleValue extends CallArgumentValue {
  const _CallArgumentRuleValue(this.rule);

  final Rule rule;

  @override
  Object? resolve(GuardEnvironment env) => rule;

  @override
  Object? resolveData() => rule;

  @override
  String format() => rule.name.symbol;

  @override
  void collectRules(Set<Rule> rules) {
    rules.add(rule);
  }

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentPatternValue extends CallArgumentValue {
  const _CallArgumentPatternValue(this.pattern);

  final Pattern pattern;

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
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.pattern(transform(pattern));
}

final class _CallArgumentUnaryValue extends CallArgumentValue {
  const _CallArgumentUnaryValue(this.operator, this.operand);

  final ExpressionUnaryOperator operator;
  final CallArgumentValue operand;

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
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.unary(operator, operand.transformPatterns(transform));
}

final class _CallArgumentMemberValue extends CallArgumentValue {
  const _CallArgumentMemberValue(this.target, this.member);

  final CallArgumentValue target;
  final String member;

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
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.member(target.transformPatterns(transform), member);
}

final class _CallArgumentBinaryValue extends CallArgumentValue {
  const _CallArgumentBinaryValue(this.left, this.operator, this.right);

  final CallArgumentValue left;
  final ExpressionBinaryOperator operator;
  final CallArgumentValue right;

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
  Object? resolve(GuardEnvironment env) => callable;

  @override
  Object? resolveData() => callable;

  @override
  String format() => callable.toString();

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

/// Captured callable pattern value.
///
/// This keeps the callable surface explicit when semantic actions need to
/// return a higher-order parser value as ordinary data.
final class PatternClosureValue {
  const PatternClosureValue(this.body, this.environment);

  final Pattern body;
  final GuardEnvironment environment;

  String get key => _patternClosureKey(body, environment);

  PatternClosureValue apply(Map<String, Object?> arguments) {
    if (arguments.isEmpty) {
      return this;
    }
    return PatternClosureValue(body, environment.mergeWith(arguments));
  }

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
  _writeCanonicalString(buffer, environment.rule.name.symbol);
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
        rule.name.symbol,
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
    Neg(:var pattern) => Neg(_resolvePatternValue(pattern, env)),
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
    List<dynamic> items => CallArgumentValue.list(
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
  Object? resolve(GuardEnvironment env) => env.rule;

  @override
  Object? resolveData() => null;

  @override
  String format() => "rule";

  @override
  void collectRules(Set<Rule> rules) {}

  @override
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) => this;
}

final class _CallArgumentListValue extends CallArgumentValue {
  const _CallArgumentListValue(this.values);

  final List<CallArgumentValue> values;

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
  CallArgumentValue transformPatterns(Pattern Function(Pattern pattern) transform) =>
      CallArgumentValue.list(values.map((value) => value.transformPatterns(transform)).toList());
}

final class _CallArgumentMapValue extends CallArgumentValue {
  const _CallArgumentMapValue(this.values);

  final Map<String, CallArgumentValue> values;

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
final class GuardEnvironment {
  GuardEnvironment({
    required this.rule,
    GlushList<Mark> marks = const GlushList<Mark>.empty(),
    this.arguments = const <String, Object?>{},
    this.values = const <String, Object?>{},
    CallArgumentsKey? valuesKey,
    this.valueResolver,
    this.captureResolver,
    this.rulesByName = const <String, Rule>{},
  }) : _marksForest = marks,
       valuesKey =
           valuesKey ??
           (values.isEmpty
               ? const EmptyCallArgumentsKey()
               : StringCallArgumentsKey(_formatObjectMap(values)));

  final Rule rule;
  final GlushList<Mark> _marksForest;
  final Map<String, Object?> arguments;
  final Map<String, Object?> values;
  final CallArgumentsKey valuesKey;
  final Object? Function(String name)? valueResolver;
  final CaptureValue? Function(GlushList<Mark>, String)? captureResolver;
  final Map<String, Rule> rulesByName;

  final Map<String, CaptureValue?> _captureCache = {};

  CaptureValue? _resolveCapture(String name) {
    if (_captureCache.containsKey(name)) {
      return _captureCache[name];
    }

    var capture = captureResolver?.call(_marksForest, name);
    _captureCache[name] = capture;
    return capture;
  }

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
    return _resolveCapture(name) ?? rulesByName[name];
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

sealed class GuardValue {
  const GuardValue();

  // Guard values are typed separately from call arguments so expression
  // evaluation can tell runtime data, rule references, and the special `rule`
  // symbol apart.
  factory GuardValue.literal(Object? value) = _GuardLiteralValue;
  factory GuardValue.argument(String name) = _GuardArgumentValue;
  factory GuardValue.name(String name) = _GuardNameValue;
  factory GuardValue.rule() = _GuardRuleValue;

  Object? evaluate(GuardEnvironment env);

  GuardExpr eq(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.eq);
  GuardExpr ne(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.ne);
  GuardExpr gt(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.gt);
  GuardExpr gte(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.gte);
  GuardExpr lt(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.lt);
  GuardExpr lte(Object? other) =>
      _GuardComparison(this, _coerceGuardValue(other), _GuardComparisonKind.lte);
}

sealed class GuardExpr {
  const GuardExpr();

  // Guard expressions are a tiny boolean AST that the runtime can evaluate
  // directly inside the state machine.
  factory GuardExpr.literal(bool value) = _GuardLiteralExpr;
  factory GuardExpr.value(GuardValue value) = GuardValueExpr;
  factory GuardExpr.expression(CallArgumentValue value) = _GuardExpressionExpr;

  bool evaluate(GuardEnvironment env);

  GuardExpr and(GuardExpr other) => GuardAnd(this, other);
  GuardExpr or(GuardExpr other) => GuardOr(this, other);
  GuardExpr not() => GuardNot(this);

  GuardExpr operator &(GuardExpr other) => and(other);
  GuardExpr operator |(GuardExpr other) => or(other);
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
}

final class _GuardArgumentValue extends GuardValue {
  const _GuardArgumentValue(this.name);

  final String name;

  @override
  Object? evaluate(GuardEnvironment env) => env.resolve(name);
}

final class _GuardNameValue extends GuardValue {
  const _GuardNameValue(this.name);

  final String name;

  @override
  Object? evaluate(GuardEnvironment env) => env.resolve(name);
}

final class _GuardRuleValue extends GuardValue {
  const _GuardRuleValue();

  @override
  Object? evaluate(GuardEnvironment env) => env.rule;
}

final class _GuardLiteralExpr extends GuardExpr {
  const _GuardLiteralExpr(this.value);

  final bool value;

  @override
  bool evaluate(GuardEnvironment env) => value;
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
}

final class GuardAnd extends GuardExpr {
  const GuardAnd(this.left, this.right);

  final GuardExpr left;
  final GuardExpr right;

  @override
  bool evaluate(GuardEnvironment env) => left.evaluate(env) && right.evaluate(env);
}

final class GuardOr extends GuardExpr {
  const GuardOr(this.left, this.right);

  final GuardExpr left;
  final GuardExpr right;

  @override
  bool evaluate(GuardEnvironment env) => left.evaluate(env) || right.evaluate(env);
}

final class GuardNot extends GuardExpr {
  const GuardNot(this.child);

  final GuardExpr child;

  @override
  bool evaluate(GuardEnvironment env) => !child.evaluate(env);
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

/// Resolved capture data from a labeled mark span.
final class CaptureValue {
  const CaptureValue(this.startPosition, this.endPosition, this.value);

  final int startPosition;
  final int endPosition;
  final String value;

  int get length => endPosition - startPosition;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => value;
}

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
  Iterable<(Pattern, Pattern)> eachPair() sync* {}

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
  Pattern plus() => Plus(this);
  Pattern star() => Star(this);
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
      Backreference() => "bac",
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
      ParameterRefPattern(:var name) => name,
      ParameterCallPattern(:var name, minPrecedenceLevel: var prec) =>
        "$name${prec == null ? "" : prec.toString()}",
      Action() => "",
      Prec(precedenceLevel: var prec) => "$prec",
      Opt() => "",
      Plus() => "",
      Star() => "",
      Label(:var name) => name,
      LabelStart(:var name) => name,
      LabelEnd(:var name) => name,
      Backreference(:var name) => name,
    };
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

  /// Span-level negation (NEG) - matches if pattern does NOT match the EXACT span (i,j).
  /// Consumes input.
  /// Example: ident & neg(keyword) matches an identifier that is not a keyword.
  Neg neg() => Neg(this);
}

/// Sealed class hierarchy for token choice — replaces the former dynamic field.
sealed class TokenChoice {
  const TokenChoice(this.capturesAsMark);
  final bool capturesAsMark;
  bool matches(int? value);
}

/// Matches any token (wildcard)
final class AnyToken extends TokenChoice {
  const AnyToken() : super(true);

  @override
  bool matches(int? value) => value != null;

  @override
  String toString() => "any";
}

/// Matches an exact code-point value
final class ExactToken extends TokenChoice {
  const ExactToken(this.value) : super(false);
  final int value;

  @override
  bool matches(int? token) => token == value;

  @override
  String toString() => String.fromCharCode(value);
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
}

/// Matches a code-point <= bound
final class LessToken extends TokenChoice {
  const LessToken(this.bound) : super(true);
  final int bound;

  @override
  bool matches(int? token) => token != null && token <= bound;

  @override
  String toString() => "less($bound)";
}

/// Matches a code-point >= bound
final class GreaterToken extends TokenChoice {
  const GreaterToken(this.bound) : super(true);
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

  bool get capturesAsMark => choice.capturesAsMark;

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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();

    // Prefer staying in the repetition before exiting in non-ambiguity mode.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
    yield* child.eachPair();

    // Prefer staying in the repetition before exiting in non-ambiguity mode.
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
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
  Iterable<(Pattern, Pattern)> eachPair() sync* {
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
  Rule(String name, this._code) : name = RuleName(name), uid = _uidCounter++;

  static int _uidCounter = 1;

  final RuleName name;
  final Pattern Function() _code;
  final List<RuleCall> calls = [];

  /// Unique serial ID assigned during Rule creation.
  /// Used for fast integer-packed cache keys.
  final int uid;

  Pattern? _body;
  GuardExpr? guard;
  Rule? guardOwner;

  RuleCall call({Map<String, CallArgumentValue> arguments = const {}, int? minPrecedenceLevel}) {
    var name = "${this.name}_${calls.length}";
    var call = RuleCall(name, this, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);
    calls.add(call);
    return call;
  }

  /// Attach a guard that must evaluate to true before the rule body is entered.
  ///
  /// Guards are enforced by the state machine, alongside precedence filtering.
  Rule guardedBy(GuardExpr guard) {
    this.guard = guard;
    return this;
  }

  Pattern body() {
    if (_body == null) {
      _body = _code().consume();
      GlushProfiler.increment("parser.rule_body.created");
    }
    return _body!;
  }

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
  String toString() => "<$name>";
}

/// Call to a rule with optional precedence constraint
class RuleCall extends Pattern {
  RuleCall(
    this.name,
    this.rule, {
    Map<String, CallArgumentValue> arguments = const {},
    this.minPrecedenceLevel,
  }) : arguments = Map<String, CallArgumentValue>.unmodifiable(arguments),
       argumentsKey = _callArgumentSourceKey(arguments),
       _argumentNames = _sortedArgumentNames(arguments.keys, const []);
  final String name;
  final Rule rule;
  final Map<String, CallArgumentValue> arguments;
  final String argumentsKey;
  final List<String> _argumentNames;

  /// Minimum precedence level filter. If set, only alternatives in the rule
  /// with precedenceLevel >= minPrecedenceLevel will match.
  /// This implements EXPR^N syntax where N is the minimum precedence level.
  final int? minPrecedenceLevel;

  @override
  RuleCall copy() =>
      RuleCall(name, rule, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);

  ({Map<String, Object?> arguments, CallArgumentsKey key}) resolveArgumentsAndKey(
    GuardEnvironment env,
  ) {
    // Resolve the typed call-argument model once at the call boundary, then
    // hand the state machine a plain resolved map and a memoization key.
    // Arguments are resolved once at the call boundary so the runtime sees a
    // plain map and a stable memoization key.
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
    // Don't call rule.body() here to avoid circular initialization issues
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

/// Reference to a rule parameter used in a rule body.
///
/// This is resolved at runtime from the current caller's argument map so rule
/// bodies can treat parameters as first-class parser values.
class ParameterRefPattern extends Pattern {
  ParameterRefPattern(this.name);

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
  String toString() => "param($name)";
}

/// Invocation of a rule parameter with call arguments.
///
/// This is used when a grammar body needs to call a parameterized rule value
/// as `content(piece: atom)` instead of just reading `content`.
class ParameterCallPattern extends Pattern {
  ParameterCallPattern(
    this.name, {
    Map<String, CallArgumentValue> arguments = const {},
    this.minPrecedenceLevel,
  }) : arguments = Map<String, CallArgumentValue>.unmodifiable(arguments),
       argumentsKey = _callArgumentSourceKey(arguments),
       _argumentNames = _sortedArgumentNames(arguments.keys, const []);

  final String name;
  final Map<String, CallArgumentValue> arguments;
  final String argumentsKey;
  final List<String> _argumentNames;
  final int? minPrecedenceLevel;

  @override
  ParameterCallPattern copy() =>
      ParameterCallPattern(name, arguments: arguments, minPrecedenceLevel: minPrecedenceLevel);

  ({Map<String, Object?> arguments, CallArgumentsKey key}) resolveArgumentsAndKey(
    GuardEnvironment env,
  ) {
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

class Backreference extends Pattern {
  Backreference(this.name);
  final String name;

  @override
  Backreference copy() => Backreference(name);

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
  String toString() => "(\\$name)";
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
