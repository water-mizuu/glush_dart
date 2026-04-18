// ignore_for_file: must_be_immutable

import "dart:math";

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:glush/src/parser/common/sppf_table.dart";
import "package:meta/meta.dart";

/// Signature for an evaluation handler.
typedef EvaluatorHandler<T extends Object> = Object? Function(EvaluationContext<T> ctx);

/// A context object passed to evaluation handlers.
///
/// This provides a clean API for accessing children and text content.
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

/// A generic evaluator for mark-based parse results and nested entry structures.
///
/// This evaluator is designed to be "porting safe" across languages:
/// 1. Uses explicit types instead of dynamic/any.
/// 2. Uses a simple class-based handler system instead of complex closures.
/// 3. Uses a stateful iterator for consuming child nodes.
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

/// Base class for all nodes in the structured parse tree.
sealed class ParseNode {
  /// The full text content of this node.
  String get span;

  /// Simplified representation of this node.
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

/// Evaluator that produces a structured tree of results based on labels.
class StructuredEvaluator {
  const StructuredEvaluator({this.sppfTable});

  /// When set, label spans derived from marks are cross-checked against the
  /// SPPF label index inside an [assert]. This is zero-cost in production
  /// (asserts are compiled out) and validates SPPF/marks parity in debug/test.
  final SppfTable? sppfTable;

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
    var stack = <_EvaluationFrame>[_EvaluationFrame("root", input: input)];

    for (var mark in lazyMarks.evaluate().iterate()) {
      switch (mark) {
        case LabelStartMark(:var name, :var position):
          stack.last.recordRange(position, position);
          stack.add(_EvaluationFrame(name, input: input, startPosition: position));
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

    // SPPF parity check: assert that the SPPF index contains at least one
    // SymbolNode that agrees with the marks-derived label span.
    // Different SymbolNodes for the same rule may have shorter spans (e.g. for
    // greedy '+' rules with intermediate completions) — that is expected.
    assert(() {
      var table = sppfTable;
      if (table == null) {
        return true;
      }
      for (var sym in table.allSymbolNodes) {
        var sppfSpan = sym.labelFor(name);
        if (sppfSpan == null) {
          continue;
        }
        if (sppfSpan.$1 == start && sppfSpan.$2 == position) {
          return true;
        }
      }
      // No node matched. This is acceptable during in-flight parses where
      // ReturnAction hasn't fired for the enclosing rule yet. Only hard-fail
      // if the table already has label entries for this name but none match.
      var hasAnyEntry = table.allSymbolNodes.any((s) => s.labelFor(name) != null);
      assert(
        !hasAnyEntry,
        'SPPF has entries for label "$name" but none match marks span '
        "[$start..$position). SPPF entries: "
        '${table.allSymbolNodes.where((s) => s.labelFor(name) != null).map((s) => '${s.labelFor(name)}@${s.start}..${s.end}').join(', ')}',
      );
      return true;
    }());
  }
}

extension StructuredEvaluatorExtension on List<Mark> {
  ParseResult evaluateStructure(String input) =>
      const StructuredEvaluator().evaluate(this, input: input);
}

class _EvaluationFrame {
  _EvaluationFrame(this.name, {required this.input, this.startPosition});
  final String name;
  final String input;
  final int? startPosition;
  final List<(String label, ParseNode node)> children = [];

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
