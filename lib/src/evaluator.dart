/// Evaluator for parse marks
library glush.evaluator;

/// A generic evaluator for mark-based parse results.
///
/// It allows defining handlers for named markers and recursively consuming
/// marks from the list.
class Evaluator<T> {
  final Map<String, dynamic Function()> Function(R Function<R>() consume) factory;

  Evaluator(this.factory);

  /// Evaluates the list of marks and returns the result along with any remaining marks.
  (T, List<String>) evaluate(List<String> marks) {
    int index = 0;
    late final Map<String, dynamic Function()> handlers;

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
    return (consume<T>(), marks.sublist(index));
  }
}
