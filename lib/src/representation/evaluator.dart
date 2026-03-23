import '../core/mark.dart';

/// Type definition for nested entry structure.
/// Entry = List<(name: string, value: Entry | String)>
typedef Entry = List<dynamic>;

/// A generic evaluator for mark-based parse results and nested entry structures.
///
/// Can evaluate both:
/// 1. Traditional mark lists: List<Mark>
/// 2. Nested entry structures: List<(name: string, value: Entry | String)>
///
/// Example for nested entries:
/// ```dart
/// final data = [("two", [("two", [("one", 's'), ("one", 's')]), ("one", 's')])];
/// final evaluator = Evaluator((consume) {
///   return {
///     "two": () => "(${consume<String>()}${consume<String>()})",
///     "one": () => consume<String>(),
///   };
/// });
/// final result = evaluator.evaluateEntry(data);
/// ```
class Evaluator<T> {
  final Map<String, Object? Function()> Function(R Function<R>() consume) factory;

  Evaluator(this.factory);

  /// Evaluates a nested entry structure and returns the result.
  ///
  /// Processes structures of the form:
  /// List<(name: string, value: Entry | String)>
  T evaluateEntry(List<Object?> entry) {
    late final Map<String, Object? Function()> handlers;
    var queue = List<Object?>.from(entry);
    var index = 0;

    R consume<R>() {
      if (index >= queue.length) {
        throw StateError('Unexpected end of entries');
      }

      final current = queue[index++];

      // If it's a tuple (name, value)
      if (current is! (String, Object?)) {
        return current as R;
      }

      final (name, value) = current;
      if (handlers.containsKey(name)) {
        // Save current state
        final previousQueue = queue;
        final previousIndex = index;

        // Set up new queue for this handler's consumption
        if (value is List) {
          queue = List<dynamic>.from(value);
        } else {
          // If value is a string, create a single-element queue
          queue = [value];
        }
        index = 0;

        final result = handlers[name]!();

        // Restore queue state
        queue = previousQueue;
        index = previousIndex;

        return result as R;
      }

      // If no handler is found, treat value as a raw value
      if (value is String) {
        return value as R;
      }

      return null as R;
    }

    handlers = factory(consume);
    queue = List<dynamic>.from(entry);
    index = 0;
    return consume<T>();
  }

  /// Evaluates a list of marks and returns the result.
  T evaluate(List<Object> marks) {
    var index = 0;
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
  /// List of (label, result) tuples.
  final List<(String, ParseResult)> children;

  /// The full text content of this result.
  @override
  final String span;

  ParseResult(this.children, this.span);

  @override
  String toString() => children.isEmpty ? 'ParseResult(span: $span)' : 'ParseResult($children)';

  Object toSimple() => children.isEmpty
      ? span //
      : [for (final (k, v) in children) (k, v.toSimple())];

  /// Get all results with a given label name.
  List<ParseResult>? get(String name) {
    final results = <ParseResult>[];
    for (final (key, result) in children) {
      if (key == name) {
        results.add(result);
      }
    }
    return results.isEmpty ? null : results;
  }

  /// Dictionary-style access to get all results with a given label.
  List<ParseResult>? operator [](String name) => get(name);
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
  final List<(String, ParseResult)> children = [];
  final StringBuffer spanBuffer = StringBuffer();

  _EvaluationFrame(this.name);

  void addChild(String label, ParseResult result) {
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
