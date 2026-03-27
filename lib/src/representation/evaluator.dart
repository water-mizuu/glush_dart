import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/profiling.dart";

/// Signature for an evaluation handler.
typedef EvaluatorHandler<T> = T Function(EvaluationContext<T> ctx);

/// A context object passed to evaluation handlers.
///
/// This provides a clean API for accessing children and text content.
class EvaluationContext<T> {
  EvaluationContext(this.evaluator, this.node, this.it);
  final Evaluator<T> evaluator;

  /// The node currently being handled.
  final ParseNode node;

  /// An iterator over the labeled children of [node].
  final NodeIterator it;

  /// Evaluates a child with the given [label].
  ///
  /// Throws if the label is not found in the current node.
  R call<R>(String label) {
    if (node is! ParseResult) {
      throw StateError('Cannot access label "$label" on leaf node');
    }
    var matches = (node as ParseResult).get(label);
    if (matches.isEmpty) {
      throw StateError('No child with label "$label" found in ${node.span}');
    }
    return evaluator.evaluate(matches.first) as R;
  }

  /// Evaluates a child with the given [label].
  ///
  /// Throws if the label is not found in the current node.
  R? optional<R extends Object>(String label) {
    if (node is! ParseResult) {
      throw StateError('Cannot access label "$label" on leaf node');
    }
    var matches = (node as ParseResult).get(label);
    if (matches.isEmpty) {
      return null;
    }

    return evaluator.evaluate(matches.first) as R;
  }

  /// Evaluates all children with the given [label] and returns them as a list.
  ///
  /// Searches the current subtree in document order and returns every match.
  /// Returns an empty list if the label does not exist anywhere below the
  /// current node.
  List<R> all<R>(String label) {
    if (node is! ParseResult) {
      return <R>[];
    }

    var results = <R>[];

    void visit(ParseNode current) {
      if (current is! ParseResult) {
        return;
      }

      for (var (childLabel, childNode) in current.children) {
        if (childLabel == label) {
          results.add(evaluator.evaluate(childNode) as R);
        }
        visit(childNode);
      }
    }

    visit(node);
    return results;
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
  Evaluator(this.handlers);

  /// Map of label names to their corresponding handlers.
  final Map<String, EvaluatorHandler<T>> handlers;

  EvaluatorHandler<T>? _resolveHandler(String label) {
    var handler = handlers[label];
    if (handler != null) {
      return handler;
    }

    var dotIndex = label.lastIndexOf(".");
    if (dotIndex != -1 && dotIndex < label.length - 1) {
      return handlers[label.substring(dotIndex + 1)];
    }

    return null;
  }

  /// Evaluates a [ParseNode] and returns the result of type [T].
  T evaluate(ParseNode node) {
    return GlushProfiler.measure("evaluator.evaluate_node", () {
      if (node is TokenResult) {
        return translateToken(node);
      }

      if (node is ParseResult) {
        if (node.children.isEmpty) {
          return translateToken(node);
        }
        var it = NodeIterator(node.children);
        return evaluateChildren(it);
      }

      throw UnimplementedError("Unknown node type: ${node.runtimeType}");
    });
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
      throw StateError("Cannot evaluate empty children list");
    }
    var first = it.next();
    var current = first;

    while (true) {
      var (label, node) = current;
      // Walk forward until we find the first sibling with a registered handler.
      // This lets structural wrappers or ignored siblings appear before the
      // semantic node we actually want to interpret.
      var handler = _resolveHandler(label);
      if (handler != null) {
        var childIt = node is ParseResult ? NodeIterator(node.children) : NodeIterator(const []);

        // Auto-flatten redundant same-named nested results (common in rule calls wrapping labeled alternatives)
        while (childIt.hasNext && childIt.remainingCount == 1 && childIt.peek().$1 == label) {
          node = childIt.next().$2;
          childIt = node is ParseResult
              ? NodeIterator(node.children) //
              : NodeIterator(const []);
        }

        var ctx = EvaluationContext(this, node, childIt);

        return normalizeSemanticValue(handler.call(ctx)) as T;
      }

      if (!it.hasNext) {
        return normalizeSemanticValue(evaluate(first.$2)) as T;
      }
      current = it.next();
    }
  }
}

/// An iterator over labeled parse nodes.
class NodeIterator {
  NodeIterator(this._nodes);
  final List<(String label, ParseNode node)> _nodes;
  int _index = 0;

  bool get hasNext => _index < _nodes.length;
  int get remainingCount => _nodes.length - _index;

  (String label, ParseNode node) next() {
    if (!hasNext) {
      throw StateError("No more nodes");
    }

    return _nodes[_index++];
  }

  /// Peek at the next node without consuming it.
  (String label, ParseNode node) peek() {
    if (!hasNext) {
      throw StateError("No more nodes");
    }

    return _nodes[_index];
  }

  /// Skips the next node.
  void skip() {
    if (!hasNext) {
      throw StateError("No more nodes to skip");
    }
    _index++;
  }

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
  TokenResult(this.span);
  @override
  final String span;

  @override
  String toString() => 'Token("$span")';
}

/// A node in the structured parse result tree
class ParseResult extends ParseNode {
  ParseResult(this.children, this.span);

  /// List of (label, result) tuples.
  final List<(String label, ParseNode node)> children;
  Map<String, List<ParseNode>>? _childrenByLabel;

  /// The full text content of this result.
  @override
  final String span;

  @override
  String toString() => children.isEmpty ? "ParseResult(span: $span)" : "ParseResult($children)";

  /// Get all results with a given label name.
  List<ParseNode> get(String name) {
    if (_childrenByLabel == null) {
      var grouped = <String, List<ParseNode>>{};
      for (var (String key, ParseNode node) in children) {
        grouped.putIfAbsent(key, () => []).add(node);
      }
      _childrenByLabel = grouped.map(
        (key, value) => MapEntry(key, List<ParseNode>.unmodifiable(value)),
      );
    }

    return _childrenByLabel![name] ?? const [];
  }

  /// Dictionary-style access to get all results with a given label.
  List<ParseNode> operator [](String name) => get(name);
}

/// Evaluator that produces a structured tree of results based on labels.
class StructuredEvaluator {
  const StructuredEvaluator();

  ParseResult evaluate(List<Mark> marks) {
    return GlushProfiler.measure("evaluator.evaluate_marks", () {
      var stack = <_EvaluationFrame>[_EvaluationFrame("")];

      for (var mark in marks) {
        switch (mark) {
          case LabelStartMark(:var name):
            stack.add(_EvaluationFrame(name));
          case LabelEndMark(:var name, :var position):
            _closeLabel(stack, name, position);
          case NamedMark(:var name):
            if (stack.last.children.isNotEmpty) {
              var lastChild = stack.last.children.removeLast();
              var newNode = ParseResult([(lastChild.$1, lastChild.$2)], lastChild.$2.span);
              stack.last.children.add((name, newNode));
            } else {
              var newNode = ParseResult([], stack.last.spanBuffer.toString());
              stack.last.children.add((name, newNode));
            }

          case ConjunctionMark(:var branches):
            var first = true;
            for (var branch in branches) {
              var branchResult = evaluate(branch.toList());
              for (var child in branchResult.children) {
                stack.last.children.add(child);
              }
              if (first) {
                stack.last.addToken(branchResult.span);
                first = false;
              }
            }
          case StringMark(:var value):
            stack.last.addToken(value);
        }
      }

      if (stack.length != 1) {
        _closeRemainingLabels(stack);
      }

      return stack.first.toResult();
    });
  }

  void _closeLabel(List<_EvaluationFrame> stack, String name, int position) {
    if (stack.length <= 1) {
      return;
    }

    var matchIndex = stack.length - 1;
    while (matchIndex > 0 && stack[matchIndex].name != name) {
      matchIndex--;
    }

    if (matchIndex == 0 && stack[0].name != name) {
      return;
    }

    while (stack.length - 1 > matchIndex) {
      var frame = stack.removeLast();
      stack.last.addChild(frame.name, frame.toResult());
    }

    var frame = stack.removeLast();
    stack.last.addChild(frame.name, frame.toResult());
  }

  void _closeRemainingLabels(List<_EvaluationFrame> stack) {
    while (stack.length > 1) {
      var frame = stack.removeLast();
      stack.last.addChild(frame.name, frame.toResult());
    }
  }

  ParseResult evaluateStrict(List<Mark> marks) {
    var stack = <_EvaluationFrame>[_EvaluationFrame("")];

    for (var mark in marks) {
      switch (mark) {
        case LabelStartMark(:var name):
          stack.add(_EvaluationFrame(name));
        case LabelEndMark(:var name, :var position):
          _closeStrictLabel(stack, name, position);
        case NamedMark(:var name):
          if (stack.last.children.isNotEmpty) {
            var lastChild = stack.last.children.removeLast();
            var newNode = ParseResult([(lastChild.$1, lastChild.$2)], lastChild.$2.span);
            stack.last.children.add((name, newNode));
          } else {
            var newNode = ParseResult([], stack.last.spanBuffer.toString());
            stack.last.children.add((name, newNode));
          }

        case ConjunctionMark(:var branches):
          var first = true;
          for (var branch in branches) {
            var branchResult = evaluateStrict(branch.toList());
            for (var child in branchResult.children) {
              stack.last.children.add(child);
            }
            if (first) {
              stack.last.addToken(branchResult.span);
              first = false;
            }
          }
        case StringMark(:var value):
          stack.last.addToken(value);
      }
    }

    if (stack.length != 1) {
      var openLabels = stack.skip(1).map((frame) => frame.name).toList();
      throw StateError("Unclosed label(s) at end of mark stream: $openLabels");
    }

    return stack.first.toResult();
  }

  void _closeStrictLabel(List<_EvaluationFrame> stack, String name, int position) {
    if (stack.length <= 1) {
      throw StateError('Unexpected label end "$name" at position $position');
    }

    var frame = stack.last;
    if (frame.name != name) {
      throw StateError(
        'Mismatched label end "$name" at position $position; '
        'expected "${frame.name}"',
      );
    }

    stack.removeLast();
    stack.last.addChild(frame.name, frame.toResult());
  }
}

extension StructuredEvaluatorExtension on List<Mark> {
  ParseResult evaluateStructure() => const StructuredEvaluator().evaluate(this);
}

class _EvaluationFrame {
  _EvaluationFrame(this.name);
  final String name;
  final List<(String label, ParseNode node)> children = [];
  final StringBuffer spanBuffer = StringBuffer();

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
