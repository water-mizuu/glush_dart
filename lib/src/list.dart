/// Custom list implementation for managing parse alternatives
library glush.list;

abstract class GlushList<T> {
  static GlushList<T> empty<T>() => EmptyList<T>._();

  static GlushList<T> branched<T>(List<GlushList<T>> alternatives) {
    if (alternatives.length == 1) {
      return alternatives[0];
    }
    return BranchedList<T>._(alternatives);
  }

  GlushList<T> add(T data) {
    return Push<T>._(this, data);
  }

  GlushList<T> addList(GlushList<T> list) {
    return Concat<T>._(this, list);
  }

  List<T> toList() {
    final result = <T>[];
    forEach((item) => result.add(item));
    return result;
  }

  void forEach(void Function(T) callback);

  bool isEmpty() {
    try {
      forEach((_) {
        throw _StopIteration();
      });
      return true;
    } on _StopIteration {
      return false;
    }
  }
}

class _StopIteration implements Exception {}

class EmptyList<T> extends GlushList<T> {
  EmptyList._();

  @override
  void forEach(void Function(T) callback) {
    // Empty list does nothing
  }
}

class BranchedList<T> extends GlushList<T> {
  final List<GlushList<T>> alternatives;

  BranchedList._(this.alternatives);

  @override
  void forEach(void Function(T) callback) {
    if (alternatives.length != 1) {
      throw Exception('ambiguous');
    }
    alternatives[0].forEach(callback);
  }
}

class Push<T> extends GlushList<T> {
  final GlushList<T> parent;
  final T data;

  Push._(this.parent, this.data);

  @override
  void forEach(void Function(T) callback) {
    parent.forEach(callback);
    callback(data);
  }
}

class Concat<T> extends GlushList<T> {
  final GlushList<T> left;
  final GlushList<T> right;

  Concat._(this.left, this.right);

  @override
  void forEach(void Function(T) callback) {
    left.forEach(callback);
    right.forEach(callback);
  }
}
