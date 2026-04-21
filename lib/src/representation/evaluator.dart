// ignore_for_file: must_be_immutable

import "dart:convert";
import "dart:math";

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:meta/meta.dart";

/// Signature for an evaluation handler.
typedef EvaluatorHandler<T extends Object> = Object? Function(EvaluationContext<T> ctx);

/// A context object provided to [EvaluatorHandler] functions during evaluation.
///
/// The context manages the traversal of a specific node's children, allowing
/// handlers to look up children by label, iterate through them sequentially,
/// or access the raw text [span] of the current node.
class EvaluationContext<T extends Object> {
  EvaluationContext(this.evaluator, this.node, this.it);
  final Evaluator<T> evaluator;

  /// The node currently being handled.
  final ParseNode node;

  /// An iterator over the labeled children of [node].
  final NodeIterator it;

  /// Evaluates a child with the given [label].
  ///
  /// Throws if the label is not found in the current node.
  R call<R extends Object>([String? label]) {
    if (node is! ParseResult) {
      throw StateError('Cannot access label "$label" on leaf node');
    }

    if (label == null) {
      return next() as R;
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

/// A generic framework for transforming a parse forest into a high-level data model.
///
/// The [Evaluator] works by traversing a [ParseNode] tree and applying registered
/// [handlers] based on the labels (marks) found at each node. It is designed to
/// be modular and type-safe, allowing developers to define how specific grammar
/// constructs (like "binary_expression" or "function_call") should be converted
/// into Dart objects.
///
/// The evaluation process is often recursive: a handler for a parent node will
/// typically invoke the evaluator on its children to build its own state.
class Evaluator<T extends Object> {
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
        var it = NodeIterator(node.children.toList());
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
      var handler = _resolveHandler(label);
      if (handler != null) {
        var childIt = node is ParseResult
            ? NodeIterator(node.children.toList())
            : NodeIterator(const []);

        while (childIt.hasNext && childIt.remainingCount == 1 && childIt.peek().$1 == label) {
          node = childIt.next().$2;
          childIt = node is ParseResult
              ? NodeIterator(node.children.toList())
              : NodeIterator(const []);
        }

        var ctx = EvaluationContext(this, node, childIt);

        return normalizeSemanticValue(handler.call(ctx))! as T;
      }

      if (!it.hasNext) {
        return normalizeSemanticValue(evaluate(first.$2))! as T;
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

/// The common interface for all nodes in a structured parse result.
///
/// A [ParseNode] represents a successful match of a grammar pattern, either
/// as a leaf [TokenResult] or a branch [ParseResult].
sealed class ParseNode {
  /// The full text content of this node.
  String get span;

  /// Returns a simplified, JSON-compatible version of the subtree for debugging.
  Object simple();
}

/// A node representing a raw token (leaf).
@immutable
class TokenResult extends ParseNode {
  TokenResult(this.span);
  @override
  final String span;

  @override
  String toString() => 'Token("$span")';

  @override
  Object simple() => span;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenResult && runtimeType == other.runtimeType && span == other.span;

  @override
  int get hashCode => span.hashCode;
}

/// A node in the structured parse result tree
@immutable
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
        (grouped[key] ??= []).add(node);
      }
      _childrenByLabel = grouped.map(
        (key, value) => MapEntry(key, List<ParseNode>.unmodifiable(value)),
      );
    }

    return _childrenByLabel![name] ?? const [];
  }

  /// Dictionary-style access to get all results with a given label.
  List<ParseNode> operator [](String name) => get(name);

  @override
  Object simple() {
    if (children.isEmpty) {
      return span;
    }

    return [
      for (var (l, n) in children) {l: n.simple()},
    ];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParseResult &&
          runtimeType == other.runtimeType &&
          span == other.span &&
          children.length == other.children.length &&
          _childrenListEqual(children, other.children);

  bool _childrenListEqual(List<(String, ParseNode)> a, List<(String, ParseNode)> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; ++i) {
      if (a[i].$1 != b[i].$1 || a[i].$2 != b[i].$2) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(span, Object.hashAll(children));
}

/// Extension methods for converting parse trees to JSON-like structures.
extension ParseNodeJsonConversion on ParseNode {
  /// Converts a single labeled ParseNode into a simple JSON-like structure.
  ///
  /// Returns: {name: "label", span: "text", children: [{...}, ...]}
  Map<String, Object?> nodeToJson(String name) {
    var map = <String, Object?>{"name": name, "span": span};

    if (this case ParseResult parseResult when parseResult.children.isNotEmpty) {
      map["children"] = [
        for (final (label, child) in parseResult.children) child.nodeToJson(label),
      ];
    }

    return map;
  }

  /// Converts a ParseNode tree into a simple JSON-like structure.
  ///
  /// Returns a list of the direct children with their labels and spans.
  List<Map<String, Object?>> toJson() {
    if (this case ParseResult parseResult when parseResult.children.isNotEmpty) {
      return [for (final (label, child) in parseResult.children) child.nodeToJson(label)];
    }
    return [];
  }

  /// Pretty-prints this parse tree as formatted JSON.
  String toJsonString() {
    var json = toJson();
    return jsonEncode(json);
  }

  /// Pretty-prints this parse tree as formatted JSON with indentation.
  String toJsonStringPretty({String indent = "  "}) {
    var json = toJson();
    return JsonEncoder.withIndent(indent).convert(json);
  }
}

/// Transforms a flat stream of [Mark] objects into a structured [ParseResult] tree.
///
/// While the state machine produces a linear sequence of events (token matches,
/// labels, conjunctions), the [StructuredEvaluator] reconstructs the hierarchical
/// relationship between these events. It uses a stack-based approach to group
/// marks into nested [ParseResult] nodes, ensuring that labels correctly
/// encapsulate their corresponding sub-parses.
class StructuredEvaluator {
  /// Creates a structured evaluator.
  const StructuredEvaluator();

  void expandMarks(List<Mark> marks, int start, int end) {
    for (int i = end - 1; i >= start; --i) {
      if (marks[i] case ExpandingMark(name: var target)) {
        int? foundStart;
        int? foundEnd;
        for (int j = i - 1; j >= start; --j) {
          if (marks[j] case LabelEndMark(:var name) when name == target) {
            foundEnd = j;
            continue;
          }

          if (marks[j] case LabelStartMark(:var name) when name == target) {
            if (foundEnd == null) {
              throw StateError("Malformed mark list.");
            }
            foundStart = j;
            break;
          }
        }

        if (foundStart == null || foundEnd == null) {
          throw StateError("Malformed mark list.");
        }

        var sublist = marks.sublist(foundStart + 1, foundEnd);
        marks.insertAll(i, sublist);
        expandMarks(marks, i, i + sublist.length);
      }
    }
  }

  ParseResult evaluate(Object marks, {required String input}) {
    LazyGlushList<Mark> lazyMarks;
    if (marks is List<Mark>) {
      lazyMarks = LazyGlushList.fromList(marks);
    } else if (marks is LazyGlushList<Mark>) {
      lazyMarks = marks;
    } else {
      throw ArgumentError("marks must be List<Mark> or LazyGlushList<Mark>");
    }

    return _evaluate(lazyMarks, input: input).result;
  }

  ({ParseResult result, int start, int end}) _evaluate(
    LazyGlushList<Mark> lazyMarks, {
    required String input,
  }) {
    var stack = <_EvaluationFrame>[_EvaluationFrame("root", input: input, children: [])];

    for (var mark in lazyMarks.evaluate().iterate()) {
      switch (mark) {
        case LabelStartMark(:var name, :var position):
          stack.last.recordRange(position, position);
          stack.add(_EvaluationFrame(name, input: input, startPosition: position, children: []));
        case LabelEndMark(:var name, :var position):
          stack.last.recordRange(position, position);
          _closeStrictLabel(stack, name, position);
        case NamedMark(:var name, :var position):
          stack.last.recordRange(position, position);
          if (stack.last.children.isNotEmpty) {
            var lastChild = stack.last.children.removeLast();
            var newNode = ParseResult([(lastChild.$1, lastChild.$2)], lastChild.$2.span);
            stack.last.addChild(name, newNode);
          } else {
            var newNode = ParseResult([], "");
            stack.last.addChild(name, newNode);
          }
        case ExpandingMark():
          throw UnsupportedError("Marks has not been expanded.");

        case ConjunctionMark(:var left, :var right, :var position):
          stack.last.recordRange(position, position);
          var leftPath = left.evaluate().allMarkPaths().first;
          var leftEval = _evaluate(LazyGlushList.fromList(leftPath), input: input);
          stack.last.recordRange(leftEval.start, leftEval.end);
          for (var child in leftEval.result.children) {
            stack.last.children.add(child);
          }

          var rightPath = right.evaluate().allMarkPaths().first;
          var rightEval = _evaluate(LazyGlushList.fromList(rightPath), input: input);
          stack.last.recordRange(rightEval.start, rightEval.end);
          for (var child in rightEval.result.children) {
            stack.last.children.add(child);
          }
        case StringMark(:var position, :var value):
          stack.last.recordRange(position, position + value.length);
          stack.last.addChild("", TokenResult(value));
      }
    }

    if (stack.length != 1) {
      var openLabels = stack.skip(1).map((frame) => frame.name).toList();
      throw StateError("Unclosed label(s) at end of mark stream: $openLabels");
    }

    var frame = stack.first;
    var start = frame.startPosition ?? frame.minPosition ?? 0;
    var end = frame.maxPosition ?? start;
    return (result: frame.toResult(), start: start, end: end);
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
    var start = frame.startPosition ?? frame.minPosition ?? position;
    stack.last.recordRange(start, position);
    stack.last.addChild(frame.name, frame.toResult(endPosition: position));
  }
}

extension StructuredEvaluatorExtension on List<Mark> {
  ParseResult evaluateStructure(String input) =>
      const StructuredEvaluator().evaluate(this, input: input);
}

class _EvaluationFrame {
  _EvaluationFrame(this.name, {required this.input, required this.children, this.startPosition});

  final String name;
  final String input;
  final int? startPosition;
  final List<(String label, ParseNode node)> children;

  /// Minimum and maximum positions seen in marks within this frame
  int? minPosition;
  int? maxPosition;

  void addChild(String label, ParseNode result) {
    children.add((label, result));
  }

  /// Record a range of characters seen in this frame.
  void recordRange(int start, int end) {
    minPosition = minPosition == null ? start : min(minPosition!, start);
    maxPosition = maxPosition == null ? end : max(maxPosition!, end);
  }

  ParseResult toResult({int? endPosition}) {
    // If no endPosition is provided (root frame case), default to the end of input
    var effectiveEndPosition = endPosition ?? maxPosition ?? input.length;

    var start = startPosition ?? minPosition ?? 0;
    var end = effectiveEndPosition;

    // Ensure bounds are valid
    start = max(0, min(start, input.length));
    end = max(start, min(end, input.length));

    var span = input.substring(start, end);

    return ParseResult(children, span);
  }
}
