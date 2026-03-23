import '../core/mark.dart';

/// A generic evaluator for mark-based parse results.
class Evaluator<T> {
  final Map<String, Object? Function()> Function(R Function<R>() consume) factory;

  Evaluator(this.factory);

  /// Evaluates the list of marks and returns the result along with any remaining marks.
  T evaluate(List<String> marks) {
    int index = 0;
    late final Map<String, Object? Function()> handlers;

    R consume<R>() {
      if (index >= marks.length) throw StateError('Unexpected end of marks');
      final current = marks[index++];
      if (handlers.containsKey(current)) {
        final result = handlers[current]!();
        return result as R;
      }
      return current as R;
    }

    handlers = factory(consume);
    return consume<T>();
  }
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
  /// Map of labels to lists of matching results.
  final Map<String, List<ParseResult>> children;

  /// The full text content of this result.
  @override
  final String span;

  /// All results (tokens and children) in order.
  final List<ParseNode> all;

  ParseResult(this.children, this.span, this.all);

  List<ParseResult>? operator [](String key) => children[key];

  List<ParseResult>? get(String key) => children[key];

  @override
  String toString() => 'ParseResult($children)';
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
        case NamedMark():
          // Legacy support for named marks
          break;
        case StringMark(:var value):
          stack.last.addToken(value);
      }
    }

    return stack.first.toResult();
  }
}

class _EvaluationFrame {
  final String name;
  final Map<String, List<ParseResult>> children = {};
  final List<ParseNode> allResults = [];
  final StringBuffer spanBuffer = StringBuffer();

  _EvaluationFrame(this.name);

  void addChild(String label, ParseResult result) {
    if (label.isNotEmpty) {
      children.putIfAbsent(label, () => []).add(result);
    }
    spanBuffer.write(result.span);
    allResults.add(result);
  }

  void addToken(String value) {
    spanBuffer.write(value);
    allResults.add(TokenResult(value));
  }

  ParseResult toResult() {
    return ParseResult(children, spanBuffer.toString(), allResults);
  }
}
