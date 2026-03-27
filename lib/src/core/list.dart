/// Custom list implementation for managing parse alternatives
library glush.list;

import "package:glush/src/core/mark.dart";
import "package:meta/meta.dart";

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// GlushList provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed.
@immutable
sealed class GlushList<T> {
  const GlushList();
  const factory GlushList.empty() = EmptyList<T>._;

  /// Creates a branched list representing multiple parsing alternatives.
  static GlushList<T> branched<T>(List<GlushList<T>> alternatives) {
    if (alternatives.isEmpty) {
      return const EmptyList._();
    }
    if (alternatives.length == 1) {
      return alternatives[0];
    }

    return BranchedList<T>._(List.unmodifiable(alternatives));
  }

  /// Creates a GlushList from a standard Dart list.
  static GlushList<T> fromList<T>(List<T> values) {
    GlushList<T> list = const GlushList.empty();
    for (var value in values) {
      list = list.add(value);
    }
    return list;
  }

  GlushList<T> add(T data) => Push<T>._(this, data);

  GlushList<T> addList(GlushList<T> list) => switch ((this, list)) {
    (EmptyList(), var r) => r,
    (var l, EmptyList()) => l,
    _ => Concat<T>._(this, list),
  };

  List<T> toList() {
    var result = <T>[];
    forEach(result.add);
    return result;
  }

  void forEach(void Function(T) callback);

  bool get isEmpty;

  T? get lastOrNull {
    if (isEmpty) {
      return null;
    }
    T? last;
    forEach((e) => last = e);
    return last;
  }

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

bool _listEquals(List<Object?> left, List<Object?> right) {
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

class EmptyList<T> extends GlushList<T> {
  const EmptyList._();

  @override
  void forEach(void Function(T) callback) {}

  @override
  bool get isEmpty => true;

  @override
  bool operator ==(Object other) => identical(this, other) || other is EmptyList<T>;

  @override
  int get hashCode => _hashCode;

  static final int _hashCode = Object.hash(EmptyList, 0);
}

class BranchedList<T> extends GlushList<T> {
  BranchedList._(this.alternatives)
    : _isEmpty = alternatives.every((a) => a.isEmpty),
      _hashCode = Object.hash(BranchedList, Object.hashAll(alternatives));

  final List<GlushList<T>> alternatives;
  final int _hashCode;

  final bool _isEmpty;

  @override
  bool get isEmpty => _isEmpty;

  @override
  void forEach(void Function(T) callback) {
    for (var alt in alternatives) {
      alt.forEach(callback);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BranchedList<T> &&
          _hashCode == other._hashCode &&
          _listEquals(alternatives, other.alternatives);

  @override
  int get hashCode => _hashCode;
}

class Push<T> extends GlushList<T> {
  Push._(this.parent, this.data) : _lastOrNull = data, _hashCode = Object.hash(Push, parent, data);
  final GlushList<T> parent;
  final T data;
  final int _hashCode;

  final T? _lastOrNull;

  @override
  T? get lastOrNull => _lastOrNull;

  @override
  void forEach(void Function(T) callback) {
    parent.forEach(callback);
    callback(data);
  }

  @override
  bool get isEmpty => false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Push<T> &&
          _hashCode == other._hashCode &&
          parent == other.parent &&
          data == other.data;

  @override
  int get hashCode => _hashCode;
}

class Concat<T> extends GlushList<T> {
  Concat._(this.left, this.right) : _hashCode = Object.hash(Concat, left, right);
  final GlushList<T> left;
  final GlushList<T> right;
  final int _hashCode;

  @override
  void forEach(void Function(T) callback) {
    left.forEach(callback);
    right.forEach(callback);
  }

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Concat<T> &&
          _hashCode == other._hashCode &&
          left == other.left &&
          right == other.right;

  @override
  int get hashCode => _hashCode;
}

extension GlushListVisualizer<T> on GlushList<T> {
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
        var result = <List<T>>[];
        for (var alt in node.alternatives) {
          var branches = _collect(alt, memo);
          for (var branch in branches) {
            yield branch;
          }
          result.addAll(branches);
        }
        memo[node] = result;
        return;
      case Push<T>():
        var result = <List<T>>[];
        for (var path in _collect(node.parent, memo)) {
          var added = [...path, node.data];
          yield added;
          result.add(added);
        }
        memo[node] = result;
        return;
      case Concat<T>():
        var result = <List<T>>[];
        var leftPaths = _collect(node.left, memo);
        var rightPaths = _collect(node.right, memo);
        for (var l in leftPaths) {
          for (var r in rightPaths) {
            var branches = [...l, ...r];

            yield branches;
            result.add(branches);
          }
        }
        memo[node] = result;
        return;
    }
  }

  String visualize() {
    var buffer = StringBuffer();
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
    var connector = isLast ? "└── " : "├── ";
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
    var result = <String>[];
    String? currentStringMark;

    for (var mark in this) {
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
        currentStringMark = (currentStringMark ?? "") + mark.value;
      }
    }

    if (currentStringMark != null) {
      result.add(currentStringMark);
    }

    return result;
  }

  List<String> toMarkStrings() {
    var result = <String>[];
    for (var mark in this) {
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
