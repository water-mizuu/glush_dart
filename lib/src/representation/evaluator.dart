import '../core/mark.dart';

/// Signature for an evaluation handler.
typedef EvaluatorHandler<T> = T Function(EvaluationContext<T> ctx);

/// A context object passed to evaluation handlers.
///
/// This provides a clean API for accessing children and text content.
class EvaluationContext<T> {
  final Evaluator<T> evaluator;

  /// The node currently being handled.
  final ParseNode node;

  /// An iterator over the labeled children of [node].
  final NodeIterator it;

  EvaluationContext(this.evaluator, this.node, this.it);

  /// Evaluates a child with the given [label].
  ///
  /// Throws if the label is not found in the current node.
  R call<R>(String label) {
    if (node is! ParseResult) {
      throw StateError('Cannot access label "$label" on leaf node');
    }
    final matches = (node as ParseResult).get(label);
    if (matches.isEmpty) {
      throw StateError('No child with label "$label" found in ${node.span}');
    }
    return evaluator.evaluate(matches.first) as R;
  }

  /// Evaluates the next node in the iterator.
  T next() => evaluator.evaluateChildren(it);

  /// The full text content of the current node.
  String get span => node.span;
}

/// A generic evaluator for mark-based parse results and nested entry structures.
///
/// This evaluator is designed to be "porting safe" across languages:
/// 1. Uses explicit types instead of dynamic/any.
/// 2. Uses a simple class-based handler system instead of complex closures.
/// 3. Uses a stateful iterator for consuming child nodes.
///
/// Example:
/// ```dart
/// final evaluator = Evaluator<int>({
///   "add": (ctx) => ctx<int>("left") + ctx<int>("right"),
///   "num": (ctx) => int.parse(ctx.span),
/// });
/// ```
class Evaluator<T> {
  /// Map of label names to their corresponding handlers.
  final Map<String, EvaluatorHandler<T>> handlers;

  Evaluator(this.handlers);

  /// Evaluates a [ParseNode] and returns the result of type [T].
  T evaluate(ParseNode node) {
    if (node is TokenResult) {
      return translateToken(node);
    }

    if (node is ParseResult) {
      if (node.children.isEmpty) {
        return translateToken(node);
      }
      final it = NodeIterator(node.children);
      return evaluateChildren(it);
    }

    throw UnimplementedError('Unknown node type: ${node.runtimeType}');
  }

  /// Shorthand for [evaluate].
  T call(ParseNode node) => evaluate(node);

  /// Default token translation. Can be overridden.
  T translateToken(ParseNode node) {
    return node.span as T;
  }

  /// Default way to evaluate a sequence of nodes.
  /// Usually returns the result of the first node or a combined result.
  T evaluateChildren(NodeIterator it) {
    if (!it.hasNext) {
      throw StateError('Cannot evaluate empty children list');
    }
    var (label, node) = it.next();
    if (handlers.containsKey(label)) {
      var childIt = node is ParseResult
          ? NodeIterator(node.children) //
          : NodeIterator(const []);

      // Auto-flatten redundant same-named nested results (common in rule calls wrapping labeled alternatives)
      while (childIt.hasNext && childIt.remainingCount == 1 && childIt.peek().$1 == label) {
        node = childIt.next().$2;
        childIt = node is ParseResult
            ? NodeIterator(node.children) //
            : NodeIterator(const []);
      }

      final ctx = EvaluationContext(this, node, childIt);
      return handlers[label]!(ctx);
    }
    return evaluate(node);
  }
}

/// An iterator over labeled parse nodes.
class NodeIterator {
  final List<(String label, ParseNode node)> _nodes;
  int _index = 0;

  NodeIterator(this._nodes);

  bool get hasNext => _index < _nodes.length;
  int get remainingCount => _nodes.length - _index;

  (String label, ParseNode node) next() {
    if (!hasNext) throw StateError('No more nodes');
    return _nodes[_index++];
  }

  /// Peek at the next node without consuming it.
  (String label, ParseNode node) peek() {
    if (!hasNext) throw StateError('No more nodes');
    return _nodes[_index];
  }

  /// Skips the next node.
  void skip() => _index++;

  /// Returns all remaining nodes as a list.
  List<(String, ParseNode)> takeAll() => _nodes.sublist(_index);
}

/// Base class for all nodes in the structured parse tree.
sealed class ParseNode {
  /// The full text content of this node.
  String get span;
}

/// A node representing a raw token (leaf).
class TokenResult extends ParseNode {
  @override
  final String span;

  TokenResult(this.span);

  @override
  String toString() => 'Token("$span")';
}

/// A node in the structured parse result tree
class ParseResult extends ParseNode {
  /// List of (label, result) tuples.
  final List<(String label, ParseNode node)> children;
  Map<String, List<ParseNode>>? _childrenByLabel;

  /// The full text content of this result.
  @override
  final String span;

  ParseResult(this.children, this.span);

  @override
  String toString() => children.isEmpty ? 'ParseResult(span: $span)' : 'ParseResult($children)';

  /// Get all results with a given label name.
  List<ParseNode> get(String name) {
    final byLabel = _childrenByLabel ??= () {
      final grouped = <String, List<ParseNode>>{};
      for (final (key, node) in children) {
        grouped.putIfAbsent(key, () => []).add(node);
      }
      return grouped.map((key, value) => MapEntry(key, List<ParseNode>.unmodifiable(value)));
    }();
    return byLabel[name] ?? const [];
  }

  /// Dictionary-style access to get all results with a given label.
  List<ParseNode> operator [](String name) => get(name);
}

/// Evaluator that produces a structured tree of results based on labels.
class StructuredEvaluator {
  ParseResult evaluate(List<Mark> marks) {
    final stack = <_EvaluationFrame>[_EvaluationFrame('')];

    for (final mark in marks) {
      switch (mark) {
        case LabelStartMark(:var name):
          stack.add(_EvaluationFrame(name));
        case LabelEndMark():
          if (stack.length > 1) {
            final frame = stack.removeLast();
            final result = frame.toResult();
            stack.last.addChild(frame.name, result);
          }
        case NamedMark(:var name):
          if (stack.last.children.isNotEmpty) {
            final lastChild = stack.last.children.removeLast();
            final newNode = ParseResult([(lastChild.$1, lastChild.$2)], lastChild.$2.span);
            stack.last.children.add((name, newNode));
          } else {
            // Legacy fallback: if no labeled children, wrap the text matched so far
            final newNode = ParseResult([], stack.last.spanBuffer.toString());
            stack.last.children.add((name, newNode));
          }

        case StringMark(:var value):
          stack.last.addToken(value);
      }
    }

    return stack.first.toResult();
  }
}

class _EvaluationFrame {
  final String name;
  final List<(String label, ParseNode node)> children = [];
  final StringBuffer spanBuffer = StringBuffer();

  _EvaluationFrame(this.name);

  void addChild(String label, ParseNode result) {
    children.add((label, result));
    spanBuffer.write(result.span);
  }

  void addToken(String value) {
    spanBuffer.write(value);
  }

  ParseResult toResult() {
    return ParseResult(children, spanBuffer.toString());
  }
}
