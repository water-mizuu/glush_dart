/// Custom list implementation for managing parse alternatives
library glush.list;

import 'mark.dart';

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// GlushList provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed.
sealed class GlushList<T> {
  const GlushList();
  const factory GlushList.empty() = EmptyList<T>._;

  GlushList<T> add(GlushListCache<T> cache, T data) => cache.push(this, data);

  GlushList<T> addList(GlushListCache<T> cache, GlushList<T> list) => cache.concat(this, list);

  List<T> toList() {
    final result = <T>[];
    forEach(result.add);
    return result;
  }

  void forEach(void Function(T) callback);

  bool get isEmpty;

  T? get lastOrNull {
    if (isEmpty) return null;
    T? last;
    forEach((e) => last = e);
    return last;
  }
}

/// Caches shared [GlushList] nodes to form a persistent forest.
class GlushListCache<T> {
  final Map<Object, GlushList<T>> _cache = {};

  GlushList<T> branched(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) return const EmptyList._();
    if (alternatives.length == 1) return alternatives[0];

    final key = _BranchedKey(List<Object?>.unmodifiable(alternatives));
    return _cache.putIfAbsent(key, () => BranchedList<T>._(List.unmodifiable(alternatives)));
  }

  GlushList<T> fromList(List<T> values) {
    GlushList<T> list = const GlushList.empty();
    for (final value in values) {
      list = push(list, value);
    }
    return list;
  }

  GlushList<T> push(GlushList<T> parent, T data) {
    final key = ('push', parent, data);
    return _cache.putIfAbsent(key, () => Push<T>._(parent, data));
  }

  GlushList<T> concat(GlushList<T> left, GlushList<T> right) {
    if (left is EmptyList<T>) return right;
    if (right is EmptyList<T>) return left;
    final key = ('concat', left, right);
    return _cache.putIfAbsent(key, () => Concat<T>._(left, right));
  }

  void clear() => _cache.clear();
}

class _BranchedKey {
  final List<Object?> elements;
  const _BranchedKey(this.elements);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BranchedKey &&
          elements.length == other.elements.length &&
          _listEquals(elements, other.elements);

  @override
  int get hashCode => Object.hashAll(elements);
}

bool _listEquals(List<Object?> left, List<Object?> right) {
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
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

extension GlushListVisualizer<T> on GlushList<T> {
  static const int maxPaths = 10000;

  Iterable<List<T>> allPaths() {
    return _collect(this, {});
  }

  Iterable<List<T>> _collect(GlushList<T> node, Map<GlushList<T>, List<List<T>>> memo) sync* {
    if (memo.containsKey(node)) {
      yield* memo[node]!;
      return;
    }

    switch (node) {
      case EmptyList<T>():
        yield const [];
        memo[node] = const [[]];
        return;
      case BranchedList<T>():
        final result = <List<T>>[];
        for (final alt in node.alternatives) {
          final branches = _collect(alt, memo);
          for (final branch in branches) {
            yield branch;
          }
          result.addAll(branches);
        }
        memo[node] = result;
        return;
      case Push<T>():
        final result = <List<T>>[];
        for (final path in _collect(node.parent, memo)) {
          final added = [...path, node.data];
          yield added;
          result.add(added);
        }
        memo[node] = result;
        return;
      case Concat<T>():
        final result = <List<T>>[];
        final leftPaths = _collect(node.left, memo);
        final rightPaths = _collect(node.right, memo);
        for (final l in leftPaths) {
          for (final r in rightPaths) {
            final branches = [...l, ...r];

            yield branches;
            result.add(branches);
          }
        }
        memo[node] = result;
        return;
    }
  }

  String visualize() {
    final buffer = StringBuffer();
    _visualize(this, buffer, "", true, {});
    return buffer.toString();
  }

  void _visualize(
    GlushList<T> node,
    StringBuffer buffer,
    String prefix,
    bool isLast,
    Set<GlushList<T>> visited,
  ) {
    final connector = isLast ? "└── " : "├── ";
    buffer.write(prefix);
    buffer.write(connector);

    if (visited.contains(node)) {
      buffer.writeln("(shared ...)");
      return;
    }
    visited.add(node);

    if (node is EmptyList<T>) {
      buffer.writeln("Empty");
    } else if (node is Push<T>) {
      buffer.writeln("Push(${node.data})");
      _visualize(node.parent, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is Concat<T>) {
      buffer.writeln("Concat");
      _visualize(node.left, buffer, prefix + (isLast ? "    " : "│   "), false, visited);
      _visualize(node.right, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is BranchedList<T>) {
      buffer.writeln("Branched");
      for (int i = 0; i < node.alternatives.length; i++) {
        _visualize(
          node.alternatives[i],
          buffer,
          prefix + (isLast ? "    " : "│   "),
          i == node.alternatives.length - 1,
          visited,
        );
      }
    }
  }
}

extension ListMarkExtractor on List<Mark> {
  List<String> toStringList() {
    final result = <String>[];
    String? currentStringMark;

    for (final mark in this) {
      if (mark is NamedMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is LabelStartMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      } else if (mark is StringMark) {
        currentStringMark = (currentStringMark ?? '') + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }

  List<String> toMarkStrings() {
    final result = <String>[];
    for (final mark in this) {
      if (mark is NamedMark) {
        result.add(mark.name);
      } else if (mark is LabelStartMark) {
        result.add(mark.name);
      } else if (mark is StringMark) {
        result.add(mark.value);
      }
    }
    return result;
  }
}
