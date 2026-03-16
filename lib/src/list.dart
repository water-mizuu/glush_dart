/// Custom list implementation for managing parse alternatives
library glush.list;

abstract class GlushList<T> {
  static GlushList<T> empty<T>() => EmptyList<T>._();

  static GlushList<T> branched<T>(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) return EmptyList<T>._();
    if (alternatives.length == 1) return alternatives[0];
    return BranchedList<T>._(alternatives);
  }

  GlushList<T> add(T data) => Push<T>._(this, data);

  GlushList<T> addList(GlushList<T> list) {
    if (list is EmptyList<T>) return this;
    if (this is EmptyList<T>) return list;
    return Concat<T>._(this, list);
  }

  List<T> toList() {
    final result = <T>[];
    forEach(result.add);
    return result;
  }

  void forEach(void Function(T) callback);

  bool get isEmpty;
}

class EmptyList<T> extends GlushList<T> {
  EmptyList._();

  @override
  void forEach(void Function(T) callback) {}

  @override
  bool get isEmpty => true;
}

class BranchedList<T> extends GlushList<T> {
  final List<GlushList<T>> alternatives;

  BranchedList._(this.alternatives);

  @override
  void forEach(void Function(T) callback) {
    for (final alt in alternatives) {
      alt.forEach(callback);
    }
  }

  @override
  bool get isEmpty => alternatives.every((a) => a.isEmpty);
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

  @override
  bool get isEmpty => false;
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

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;
}
