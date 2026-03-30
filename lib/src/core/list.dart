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
    var flattened = <GlushList<T>>[];
    var seen = <GlushList<T>>{};
    for (var alt in alternatives) {
      if (alt is BranchedList<T>) {
        for (var sub in alt.alternatives) {
          if (sub is! EmptyList<T> && seen.add(sub)) {
            flattened.add(sub);
          }
        }
      } else if (alt is! EmptyList<T> && seen.add(alt)) {
        flattened.add(alt);
      }
    }

    if (flattened.isEmpty) {
      return EmptyList<T>._();
    }
    if (flattened.length == 1) {
      return flattened.first;
    }

    return BranchedList<T>._(List.unmodifiable(flattened));
  }

  /// Creates a GlushList from a standard Dart list.
  static GlushList<T> fromList<T>(List<T> values) {
    GlushList<T> list = GlushList<T>.empty();
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

  static final Object _dataMarker = Object();

  void forEach(void Function(T) callback) {
    var stack = <Object?>[this];
    while (stack.isNotEmpty) {
      var item = stack.removeLast();
      if (identical(item, _dataMarker)) {
        callback(stack.removeLast() as T);
        continue;
      }

      var node = item! as GlushList<T>;
      switch (node) {
        case EmptyList<T>():
          break;
        case BranchedList<T>():
          var alternatives = node.alternatives;
          for (var i = alternatives.length - 1; i >= 0; i--) {
            stack.add(alternatives[i]);
          }
        case Push<T>():
          stack.add(node.data);
          stack.add(_dataMarker);
          stack.add(node.parent);
        case Concat<T>():
          stack.add(node.right);
          stack.add(node.left);
      }
    }
  }

  /// Returns the total number of unique flattened derivations this forest represents.
  ///
  /// This takes into account branching from [BranchedList] (sum) and combinatorial
  /// expansion from [Concat] and [ConjunctionMark] (product).
  int get derivationCount {
    return _count(this, {});
  }

  int _count(GlushList<Object?> node, Map<GlushList<Object?>, int> memo) {
    if (memo[node] case var cached?) {
      return cached;
    }

    int res;
    switch (node) {
      case EmptyList():
        res = 1;
      case BranchedList(:var alternatives):
        res = 0;
        for (var alt in alternatives) {
          res += _count(alt, memo);
        }
      case Push(:var parent, :var data):
        int mult = 1;
        if (data is ConjunctionMark) {
          for (var branch in data.branches) {
            mult *= _count(branch, memo);
          }
        }
        res = _count(parent, memo) * mult;
      case Concat(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
    }
    return memo[node] = res;
  }

  bool get isEmpty;

  T? get lastOrNull {
    if (isEmpty) {
      return null;
    }
    T? last;
    forEach((e) => last = e);
    return last;
  }
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

  Iterable<List<T>> _collect(GlushList<T> node, Set<GlushList<T>> visiting) sync* {
    switch (node) {
      case EmptyList<T>():
        yield const [];
      case BranchedList<T>():
        for (var alt in node.alternatives) {
          yield* _collect(alt, visiting);
        }
      case Push<T>():
        var data = node.data;
        if (data is ConjunctionMark) {
          var branchPaths = data.branches.map((b) => (b as GlushList).allPaths().toList()).toList();

          Iterable<List<List<Mark>>> product(int index) sync* {
            if (index == branchPaths.length) {
              yield [];
              return;
            }
            for (var path in branchPaths[index]) {
              for (var rest in product(index + 1)) {
                yield [path.cast<Mark>(), ...rest];
              }
            }
          }

          var productResults = product(0).toList();
          for (var pPath in _collect(node.parent, visiting)) {
            for (var bPaths in productResults) {
              var substituted =
                  ConjunctionMark(bPaths.map(GlushList.fromList).toList(), data.position) as T;
              yield [...pPath, substituted];
            }
          }
        } else {
          for (var pPath in _collect(node.parent, visiting)) {
            yield [...pPath, data];
          }
        }
      case Concat<T>():
        // Concat is rare but we handle it lazily
        for (var l in _collect(node.left, visiting)) {
          for (var r in _collect(node.right, visiting)) {
            yield [...l, ...r];
          }
        }
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
