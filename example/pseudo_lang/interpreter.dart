import 'package:glush/glush.dart';

/// Helper to get all results with a given label
List<ParseNode> getLabel(List<(String label, ParseNode node)> children, String label) {
  return [
    for (final (name, node) in children)
      if (name == label) node,
  ];
}

/// Helper to check if a label exists
bool hasLabel(List<(String label, ParseNode node)> children, String label) {
  return children.any((element) => element.$1 == label);
}

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
  final ParseNode node;
  const FunctionValue(this.node);

  @override
  String toString() {
    if (node is! ParseResult) return "<fn ?>";
    final names = getLabel((node as ParseResult).children, 'name');
    return "<fn ${names.isNotEmpty ? names.first.span : '?'}>";
  }
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
    final functions = getLabel(program.children, 'function');
    for (final function in functions) {
      _defineFunction(function);
    }

    final mainFunc = globals.get('main');
    if (mainFunc is FunctionValue) {
      _callFunction(mainFunc.node, []);
    }
  }

  void _defineFunction(ParseNode functionNode) {
    if (functionNode is! ParseResult) return;
    final names = getLabel(functionNode.children, 'name');
    if (names.isNotEmpty) {
      final name = names.first.span;
      globals.define(name, FunctionValue(functionNode));
    }
  }

  Value _callFunction(ParseNode functionNode, List<Value> arguments) {
    if (functionNode is! ParseResult) return const NullValue();
    final previousEnv = _environment;
    _environment = Environment(globals);

    final paramsNodeList = getLabel(functionNode.children, 'params');
    if (paramsNodeList.isNotEmpty && paramsNodeList.first is ParseResult) {
      final paramsNode = paramsNodeList.first as ParseResult;
      final names = getLabel(paramsNode.children, 'name').map((n) => n.span).toList();
      for (var i = 0; i < names.length && i < arguments.length; i++) {
        _environment.define(names[i], arguments[i]);
      }
    }

    final bodyList = getLabel(functionNode.children, 'body');
    if (bodyList.isNotEmpty) {
      final result = _executeBlock(bodyList.first);
      _environment = previousEnv;
      return result ?? const NullValue();
    }

    _environment = previousEnv;
    return const NullValue();
  }

  Value? _executeBlock(ParseNode blockNode) {
    if (blockNode is! ParseResult) return null;
    final stmts = getLabel(blockNode.children, 'stmts');
    for (final stmt in stmts) {
      final val = _executeStatement(stmt);
      if (val != null) return val;
    }
    return null;
  }

  Value? _executeStatement(ParseNode stmtNode) {
    if (stmtNode is! ParseResult) return null;
    final children = stmtNode.children;

    if (hasLabel(children, 'decl')) {
      final declList = getLabel(children, 'decl');
      if (declList.isNotEmpty && declList.first is ParseResult) {
        final decl = declList.first as ParseResult;
        final names = getLabel(decl.children, 'name');
        final values = getLabel(decl.children, 'value');
        if (names.isNotEmpty && values.isNotEmpty) {
          final name = names.first.span;
          final value = _evaluateExpression(values.first);
          _environment.define(name, value);
        }
      }
    } else if (hasLabel(children, 'assign')) {
      final assignList = getLabel(children, 'assign');
      if (assignList.isNotEmpty && assignList.first is ParseResult) {
        final assign = assignList.first as ParseResult;
        final names = getLabel(assign.children, 'name');
        final values = getLabel(assign.children, 'value');
        if (names.isNotEmpty && values.isNotEmpty) {
          final name = names.first.span;
          final value = _evaluateExpression(values.first);
          _environment.assign(name, value);
        }
      }
    } else if (hasLabel(children, 'call')) {
      final callList = getLabel(children, 'call');
      if (callList.isNotEmpty) {
        _executeFunctionCall(callList.first);
      }
    } else if (hasLabel(children, 'ifStmt')) {
      final ifStmtList = getLabel(children, 'ifStmt');
      if (ifStmtList.isNotEmpty && ifStmtList.first is ParseResult) {
        final ifStmt = ifStmtList.first as ParseResult;
        final conditions = getLabel(ifStmt.children, 'cond');
        final thenBlocks = getLabel(ifStmt.children, 'then');
        if (conditions.isNotEmpty && thenBlocks.isNotEmpty) {
          final condition = _evaluateExpression(conditions.first);
          if (_isTruthy(condition)) {
            return _executeBlock(thenBlocks.first);
          } else if (hasLabel(ifStmt.children, 'else')) {
            final elseBlocks = getLabel(ifStmt.children, 'else');
            if (elseBlocks.isNotEmpty) {
              return _executeBlock(elseBlocks.first);
            }
          }
        }
      }
    } else if (hasLabel(children, 'whileStmt')) {
      final whileStmtList = getLabel(children, 'whileStmt');
      if (whileStmtList.isNotEmpty && whileStmtList.first is ParseResult) {
        final whileStmt = whileStmtList.first as ParseResult;
        final conditions = getLabel(whileStmt.children, 'cond');
        final bodies = getLabel(whileStmt.children, 'body');
        if (conditions.isNotEmpty && bodies.isNotEmpty) {
          while (_isTruthy(_evaluateExpression(conditions.first))) {
            final result = _executeBlock(bodies.first);
            if (result != null) return result;
          }
        }
      }
    }
    return null;
  }

  void _executeFunctionCall(ParseNode callNode) {
    if (callNode is! ParseResult) return;
    final names = getLabel(callNode.children, 'name');
    if (names.isEmpty) return;

    final name = names.first.span;
    final argsNodes = getLabel(callNode.children, 'arguments');
    final args = <Value>[];

    if (argsNodes.isNotEmpty && argsNodes.first is ParseResult) {
      final argsNode = argsNodes.first as ParseResult;
      final heads = getLabel(argsNode.children, 'head');
      if (heads.isNotEmpty) {
        args.add(_evaluateExpression(heads.first));
      }
      final tails = getLabel(argsNode.children, 'tail');
      for (final tail in tails) {
        args.add(_evaluateExpression(tail));
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

  Value _evaluateExpression(ParseNode exprNode) {
    if (exprNode is! ParseResult) throw Exception("Expected ParseResult for expression");
    final lefts = getLabel(exprNode.children, 'left');
    if (lefts.isEmpty) throw Exception("No left operand in expression");

    var result = _evaluatePrimary(lefts.first);

    final ops = getLabel(exprNode.children, 'op');
    final rights = getLabel(exprNode.children, 'right');

    for (var i = 0; i < ops.length && i < rights.length; i++) {
      final op = ops[i].span;
      final right = _evaluatePrimary(rights[i]);
      result = _applyOperator(result, op, right);
    }

    return result;
  }

  Value _evaluatePrimary(ParseNode primaryNode) {
    if (primaryNode is! ParseResult) throw Exception("Expected ParseResult for primary");
    final vals = getLabel(primaryNode.children, 'val');
    if (vals.isNotEmpty) {
      return IntValue(int.parse(vals.first.span));
    }

    final refs = getLabel(primaryNode.children, 'ref');
    if (refs.isNotEmpty) {
      return _environment.get(refs.first.span);
    }

    final expressions = getLabel(primaryNode.children, 'expression');
    if (expressions.isNotEmpty) {
      return _evaluateExpression(expressions.first);
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
