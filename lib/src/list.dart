/// Custom list implementation for managing parse alternatives
library glush.list;

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// GlushList provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed.
sealed class GlushList<T> {
  static GlushList<T> branched<T>(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) return EmptyList<T>._();
    if (alternatives.length == 1) return alternatives[0];
    return BranchedList<T>._(alternatives);
  }

  const GlushList();
  const factory GlushList.empty() = EmptyList<T>._;

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
  const EmptyList._();

  @override
  void forEach(void Function(T) callback) {}

  @override
  bool get isEmpty => true;
}

class BranchedList<T> extends GlushList<T> {
  final List<GlushList<T>> alternatives;

  const BranchedList._(this.alternatives);

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

  const Push._(this.parent, this.data);

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

  const Concat._(this.left, this.right);

  @override
  void forEach(void Function(T) callback) {
    left.forEach(callback);
    right.forEach(callback);
  }

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;
}
