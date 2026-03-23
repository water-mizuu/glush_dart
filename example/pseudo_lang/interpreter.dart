import 'package:glush/glush.dart';

/// Base class for all values in the pseudo-language.
sealed class Value {
  const Value();

  /// Helper to get the underlying integer value or throw a type error.
  int asInt() => throw Exception("TypeError: Expected Integer, got $runtimeType");

  /// Helper to get the underlying boolean value or throw a type error.
  bool asBool() => throw Exception("TypeError: Expected Boolean, got $runtimeType");
}

class IntValue extends Value {
  final int value;
  const IntValue(this.value);

  @override
  int asInt() => value;

  @override
  String toString() => value.toString();
}

class BoolValue extends Value {
  final bool value;
  const BoolValue(this.value);

  @override
  bool asBool() => value;

  @override
  String toString() => value.toString();
}

class FunctionValue extends Value {
  final ParseResult node;
  const FunctionValue(this.node);

  @override
  String toString() => "<fn ${node['name']!.first.span}>";
}

class NullValue extends Value {
  const NullValue();

  @override
  String toString() => "null";
}

/// Manages variable scopes and function definitions for the interpreter.
class Environment {
  final Map<String, Value> _values = {};
  final Environment? parent;

  Environment([this.parent]);

  void define(String name, Value value) {
    _values[name] = value;
  }

  void assign(String name, Value value) {
    if (_values.containsKey(name)) {
      _values[name] = value;
      return;
    }

    if (parent != null) {
      parent!.assign(name, value);
      return;
    }

    throw Exception("Undefined variable '$name'.");
  }

  Value get(String name) {
    if (_values.containsKey(name)) {
      return _values[name]!;
    }

    if (parent != null) {
      return parent!.get(name);
    }

    throw Exception("Undefined variable '$name'.");
  }
}

/// A tree-walking interpreter for the pseudo-programming language.
class Interpreter {
  final Environment globals = Environment();
  late Environment _environment;

  Interpreter() {
    _environment = globals;
  }

  void execute(ParseResult program) {
    if (program.children.containsKey('function')) {
      for (final function in program.children['function']!) {
        _defineFunction(function);
      }
    }

    try {
      final mainFunc = globals.get('main');
      if (mainFunc is FunctionValue) {
        _callFunction(mainFunc.node, []);
      }
    } catch (_) {
      // If no main, execute top-level statements
    }
  }

  void _defineFunction(ParseResult functionNode) {
    final name = functionNode['name']!.first.span;
    globals.define(name, FunctionValue(functionNode));
  }

  Value _callFunction(ParseResult functionNode, List<Value> arguments) {
    final previousEnv = _environment;
    _environment = Environment(globals);

    final paramsListNodes = functionNode.children['params'];
    if (paramsListNodes != null && paramsListNodes.isNotEmpty) {
      final paramsNode = paramsListNodes.first;
      final names = paramsNode.children['name']?.map((n) => n.span).toList() ?? [];
      for (var i = 0; i < names.length && i < arguments.length; i++) {
        _environment.define(names[i], arguments[i]);
      }
    }

    final body = functionNode['body']!.first;
    final result = _executeBlock(body);

    _environment = previousEnv;
    return result ?? const NullValue();
  }

  Value? _executeBlock(ParseResult blockNode) {
    final stmts = blockNode.children['stmts'];
    if (stmts != null) {
      for (final stmt in stmts) {
        final val = _executeStatement(stmt);
        if (val != null) return val;
      }
    }
    return null;
  }

  Value? _executeStatement(ParseResult stmtNode) {
    if (stmtNode.children.containsKey('decl')) {
      final decl = stmtNode['decl']!.first;
      final name = decl['name']!.first.span;
      final value = _evaluateExpression(decl['value']!.first);
      _environment.define(name, value);
    } else if (stmtNode.children.containsKey('assign')) {
      final assign = stmtNode['assign']!.first;
      final name = assign['name']!.first.span;
      final value = _evaluateExpression(assign['value']!.first);
      _environment.assign(name, value);
    } else if (stmtNode.children.containsKey('call')) {
      final call = stmtNode['call']!.first;
      _executeFunctionCall(call);
    } else if (stmtNode.children.containsKey('ifStmt')) {
      final ifStmt = stmtNode['ifStmt']!.first;
      final condition = _evaluateExpression(ifStmt['cond']!.first);
      if (_isTruthy(condition)) {
        return _executeBlock(ifStmt['then']!.first);
      } else if (ifStmt.children.containsKey('else')) {
        return _executeBlock(ifStmt['else']!.first);
      }
    } else if (stmtNode.children.containsKey('whileStmt')) {
      final whileStmt = stmtNode['whileStmt']!.first;
      while (_isTruthy(_evaluateExpression(whileStmt['cond']!.first))) {
        final result = _executeBlock(whileStmt['body']!.first);
        if (result != null) return result;
      }
    }
    return null;
  }

  void _executeFunctionCall(ParseResult callNode) {
    final name = callNode['name']!.first.span;
    final argsNode = callNode.children['arguments']?.firstOrNull;
    final args = <Value>[];

    if (argsNode != null) {
      if (argsNode.children.containsKey('head')) {
        args.add(_evaluateExpression(argsNode['head']!.first));
      }
      if (argsNode.children.containsKey('tail')) {
        for (final tail in argsNode.children['tail']!) {
          args.add(_evaluateExpression(tail));
        }
      }
    }

    if (name == 'print') {
      print("${args.join(', ')}");
    } else {
      final val = globals.get(name);
      if (val is FunctionValue) {
        _callFunction(val.node, args);
      } else {
        throw Exception("RuntimeError: Cannot call non-function '$name'.");
      }
    }
  }

  Value _evaluateExpression(ParseResult exprNode) {
    var result = _evaluatePrimary(exprNode['left']!.first);

    final ops = exprNode.children['op'];
    final rights = exprNode.children['right'];

    if (ops != null && rights != null) {
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i].span;
        final right = _evaluatePrimary(rights[i]);
        result = _applyOperator(result, op, right);
      }
    }

    return result;
  }

  Value _evaluatePrimary(ParseResult primaryNode) {
    if (primaryNode.children.containsKey('val')) {
      return IntValue(int.parse(primaryNode['val']!.first.span));
    } else if (primaryNode.children.containsKey('ref')) {
      return _environment.get(primaryNode['ref']!.first.span);
    } else if (primaryNode.children.containsKey('expression')) {
      return _evaluateExpression(primaryNode['expression']!.first);
    }
    throw Exception("Unknown primary expression.");
  }

  Value _applyOperator(Value left, String op, Value right) {
    switch (op) {
      case '+':
        return IntValue(left.asInt() + right.asInt());
      case '-':
        return IntValue(left.asInt() - right.asInt());
      case '*':
        return IntValue(left.asInt() * right.asInt());
      case '/':
        return IntValue(left.asInt() ~/ right.asInt());
      case '==':
        if (left is IntValue && right is IntValue) return BoolValue(left.value == right.value);
        if (left is BoolValue && right is BoolValue) return BoolValue(left.value == right.value);
        return const BoolValue(false);
      case '!=':
        if (left is IntValue && right is IntValue) return BoolValue(left.value != right.value);
        if (left is BoolValue && right is BoolValue) return BoolValue(left.value != right.value);
        return const BoolValue(true);
      case '<':
        return BoolValue(left.asInt() < right.asInt());
      case '>':
        return BoolValue(left.asInt() > right.asInt());
      case '<=':
        return BoolValue(left.asInt() <= right.asInt());
      case '>=':
        return BoolValue(left.asInt() >= right.asInt());
      default:
        throw Exception("Unknown operator '$op'.");
    }
  }

  bool _isTruthy(Value value) {
    if (value is BoolValue) return value.value;
    if (value is IntValue) return value.value != 0;
    if (value is NullValue) return false;
    return true;
  }
}
