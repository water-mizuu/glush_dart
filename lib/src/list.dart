/// Custom list implementation for managing parse alternatives
library glush.list;

import 'package:glush/src/mark.dart';

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// GlushList provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed.
sealed class GlushList<T> {
  const GlushList();
  const factory GlushList.empty() = EmptyList<T>._;

  GlushList<T> add(GlushListManager<T> manager, T data) => manager.push(this, data);

  GlushList<T> addList(GlushListManager<T> manager, GlushList<T> list) =>
      manager.concat(this, list);

  List<T> toList() {
    final result = <T>[];
    forEach(result.add);
    return result;
  }

  void forEach(void Function(T) callback);

  bool get isEmpty;
}

/// Manages deduplication of [GlushList] nodes to form a shared forest.
class GlushListManager<T> {
  final Map<Object, GlushList<T>> _cache = {};

  GlushList<T> branched(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) return const EmptyList._();
    if (alternatives.length == 1) return alternatives[0];

    // Deduplicate alternatives
    final uniqueAlt = alternatives.toSet().toList();
    if (uniqueAlt.length == 1) return uniqueAlt[0];

    uniqueAlt.sort((a, b) => a.hashCode.compareTo(b.hashCode));

    final key = _BranchedKey(uniqueAlt);
    return _cache.putIfAbsent(key, () => BranchedList<T>._(List.unmodifiable(uniqueAlt)));
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
  _BranchedKey(this.elements);

  @override
  bool operator ==(Object other) =>
      other is _BranchedKey &&
      elements.length == other.elements.length &&
      elements.indexed.every((e) => e.$2 == other.elements[e.$1]);

  @override
  int get hashCode => Object.hashAll(elements);
}

final Expando<int> _glushListHashes = Expando();

class EmptyList<T> extends GlushList<T> {
  const EmptyList._();

  @override
  void forEach(void Function(T) callback) {}

  @override
  bool get isEmpty => true;

  @override
  bool operator ==(Object other) => other is EmptyList;

  @override
  int get hashCode => 0;
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BranchedList<T> &&
          alternatives.length == other.alternatives.length &&
          alternatives.indexed.every((e) => e.$2 == other.alternatives[e.$1]);

  @override
  int get hashCode => _glushListHashes[this] ??= Object.hashAll(alternatives);
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Push<T> && parent == other.parent && data == other.data;

  @override
  int get hashCode => _glushListHashes[this] ??= Object.hash(parent, data);
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Concat<T> && left == other.left && right == other.right;

  @override
  int get hashCode => _glushListHashes[this] ??= Object.hash(left, right);
}

extension GlushListVisualizer<T> on GlushList<T> {
  static const int maxPaths = 10000;

  List<List<T>> allPaths() {
    return _collect(this, {});
  }

  List<List<T>> _collect(GlushList<T> node, Map<GlushList<T>, List<List<T>>> memo) {
    if (memo.containsKey(node)) return memo[node]!;

    List<List<T>> result;
    if (node is EmptyList<T>) {
      result = [[]];
    } else if (node is Push<T>) {
      result = _collect(node.parent, memo).map((path) => [...path, node.data]).toList();
    } else if (node is Concat<T>) {
      final leftPaths = _collect(node.left, memo);
      final rightPaths = _collect(node.right, memo);
      result = [];
      for (final l in leftPaths) {
        for (final r in rightPaths) {
          result.add([...l, ...r]);
        }
      }
    } else if (node is BranchedList<T>) {
      result = [];
      for (final alt in node.alternatives) {
        result.addAll(_collect(alt, memo));
      }
    } else {
      result = [];
    }

    memo[node] = result;
    return result;
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
      } else if (mark is StringMark) {
        result.add(mark.value);
      }
    }
    return result;
  }
}
