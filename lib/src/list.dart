/// Custom list implementation for managing parse alternatives
library glush.list;

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// GlushList provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed.
sealed class GlushList<T> {
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

  final int _hash;
  GlushList._(this._hash);

  @override
  int get hashCode => _hash;
}

class EmptyList<T> extends GlushList<T> {
  EmptyList._() : super._(0);

  @override
  void forEach(void Function(T) callback) {}

  @override
  bool get isEmpty => true;

  @override
  bool operator ==(Object other) => other is EmptyList<T>;
}

class BranchedList<T> extends GlushList<T> {
  final List<GlushList<T>> alternatives;

  static int _computeHash(List<GlushList<dynamic>> alternatives) {
    int hash = 0;
    for (final alt in alternatives) {
      hash ^= alt.hashCode;
    }
    return hash;
  }

  BranchedList._(this.alternatives) : super._(_computeHash(alternatives));

  @override
  void forEach(void Function(T) callback) {
    for (final alt in alternatives) {
      alt.forEach(callback);
    }
  }

  @override
  bool get isEmpty => alternatives.every((a) => a.isEmpty);

  @override
  bool operator ==(Object other) {
    if (other is! BranchedList<T>) return false;
    if (_hash != other._hash) return false;
    if (alternatives.length != other.alternatives.length) return false;
    for (int i = 0; i < alternatives.length; i++) {
      if (alternatives[i] != other.alternatives[i]) return false;
    }
    return true;
  }
}

class Push<T> extends GlushList<T> {
  final GlushList<T> parent;
  final T data;

  Push._(this.parent, this.data) : super._(Object.hash(parent, data));

  @override
  void forEach(void Function(T) callback) {
    parent.forEach(callback);
    callback(data);
  }

  @override
  bool get isEmpty => false;

  @override
  bool operator ==(Object other) {
    if (other is! Push<T>) return false;
    if (_hash != other._hash) return false;
    return data == other.data && parent == other.parent;
  }
}

class Concat<T> extends GlushList<T> {
  final GlushList<T> left;
  final GlushList<T> right;

  Concat._(this.left, this.right) : super._(Object.hash(left, right));

  @override
  void forEach(void Function(T) callback) {
    left.forEach(callback);
    right.forEach(callback);
  }

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! Concat<T>) return false;
    if (_hash != other._hash) return false;
    return left == other.left && right == other.right;
  }
}
