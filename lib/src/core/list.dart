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
  factory GlushList.branched(GlushList<T> left, GlushList<T> right) {
    if (left.isEmpty) {
      return right;
    }

    if (right.isEmpty) {
      return left;
    }

    // Deduplicate structurally equal alternatives
    if (left == right) {
      return left;
    }

    return BranchedList<T>._(left, right);
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

  /// Creates a parallel combination (cartesian product) of mark forests.
  /// Represents left and right marks both occurring at the same span.
  static GlushList<T> conjunction<T>(GlushList<T> left, GlushList<T> right) {
    if (left.isEmpty && right.isEmpty) {
      return const GlushList.empty();
    }
    if (left.isEmpty) {
      return right;
    }
    if (right.isEmpty) {
      return left;
    }
    return Conjunction<T>._(left, right);
  }

  static final Object _dataMarker = Object();

  Iterable<T> iterate() sync* {
    var stack = <Object?>[this];
    while (stack.isNotEmpty) {
      var item = stack.removeLast();
      if (identical(item, _dataMarker)) {
        yield stack.removeLast() as T;
        continue;
      }

      var node = item! as GlushList<T>;
      switch (node) {
        case EmptyList<T>():
          break;
        case BranchedList<T>():
          if (node.right != null) {
            stack.add(node.right);
          }
          stack.add(node.left);
        case Push<T>():
          stack.add(node.data);
          stack.add(_dataMarker);
          stack.add(node.parent);
        case Concat<T>():
          stack.add(node.right);
          stack.add(node.left);
        case Conjunction<T>():
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

  int countDerivations() => _count(this, {});

  int _count(GlushList<Object?> node, Map<GlushList<Object?>, int> memo) {
    if (memo[node] case var cached?) {
      return cached;
    }

    memo[node] = 0;
    int res;
    switch (node) {
      case EmptyList():
        res = 1;
      case BranchedList(:var left, :var right):
        res = _count(left, memo);
        if (right != null) {
          res += _count(right, memo);
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
      case Conjunction(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
    }
    return memo[node] = res;
  }

  bool get isEmpty;

  T? get lastOrNull {
    if (isEmpty) {
      return null;
    }
    return iterate().last;
  }
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
  BranchedList._(this.left, [this.right])
    : _isEmpty = left.isEmpty && (right?.isEmpty ?? true),
      _hashCode = Object.hash(BranchedList, left, right);

  final GlushList<T> left;
  final GlushList<T>? right;
  final int _hashCode;

  final bool _isEmpty;

  @override
  bool get isEmpty => _isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BranchedList<T> && left == other.left && right == other.right;

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
      identical(this, other) || other is Push<T> && parent == other.parent && data == other.data;

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
      identical(this, other) || other is Concat<T> && left == other.left && right == other.right;

  @override
  int get hashCode => _hashCode;
}

/// Represents parallel marks at the same span from different derivations.
/// Used in conjunctions to express cartesian products: left and right marks
/// both occurring at the same position (their union).
class Conjunction<T> extends GlushList<T> {
  Conjunction._(this.left, this.right) : _hashCode = Object.hash(Conjunction, left, right);
  final GlushList<T> left;
  final GlushList<T> right;
  final int _hashCode;

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Conjunction<T> && left == other.left && right == other.right;

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
        yield* _collect(node.left, visiting);
        if (node.right != null) {
          yield* _collect(node.right!, visiting);
        }
      case Push<T>():
        var data = node.data;
        for (var pPath in _collect(node.parent, visiting)) {
          yield [...pPath, data];
        }
      case Concat<T>():
        // Concat is rare but we handle it lazily
        for (var l in _collect(node.left, visiting)) {
          for (var r in _collect(node.right, visiting)) {
            yield [...l, ...r];
          }
        }
      case Conjunction<T>():
        // Parallel represents cartesian product at same span.
        // Enumerate all (left, right) path combinations and emit as ConjunctionMark.
        if (T == Mark || T.toString().contains("Mark")) {
          for (var leftPath in _collect(node.left, visiting)) {
            for (var rightPath in _collect(node.right, visiting)) {
              // For nested Parallel, flatten the structure by merging ConjunctionMark branches
              List<GlushList<Mark>> branches = [];

              // Extract branches from left path (may contain nested ConjunctionMark)
              if (leftPath.length == 1 && leftPath[0] is ConjunctionMark) {
                var conjMark = leftPath[0] as ConjunctionMark;
                branches.addAll(conjMark.branches);
              } else {
                // For non-nested case, convert the path sequence into a GlushList
                branches.add(GlushList.fromList(leftPath.cast<Mark>()));
              }

              // Extract branches from right path (may contain nested ConjunctionMark)
              if (rightPath.length == 1 && rightPath[0] is ConjunctionMark) {
                var conjMark = rightPath[0] as ConjunctionMark;
                branches.addAll(conjMark.branches);
              } else {
                // For non-nested case, convert the path sequence into a GlushList
                branches.add(GlushList.fromList(rightPath.cast<Mark>()));
              }

              // Create a ConjunctionMark with all flattened branches
              // The branches now contain the actual mark sequences from each branch
              var conjMark = ConjunctionMark(branches, 0) as T;
              yield [conjMark];
            }
          }
        } else {
          // For non-Mark types, just concatenate
          for (var l in _collect(node.left, visiting)) {
            for (var r in _collect(node.right, visiting)) {
              yield [...l, ...r];
            }
          }
        }
    }
  }

  String visualize() {
    var buffer = StringBuffer();
    _visualize(this, buffer, "", true, {});
    return buffer.toString();
  }

  /// Generates a Graphviz dot format representation of the GlushList structure.
  ///
  /// Returns a dot graph string that can be rendered with graphviz tools.
  /// Useful for debugging and visualizing the internal tree structure.
  String toDot() {
    var buffer = StringBuffer();
    buffer.writeln("digraph GlushList {");
    buffer.writeln("  node [shape=box, style=rounded];");
    buffer.writeln("  rankdir=TB;");

    var nodeIds = <GlushList<T>, String>{};
    var visited = <GlushList<T>>{};
    var nodeCounter = 0;

    void generateNodeId(GlushList<T> node) {
      if (!nodeIds.containsKey(node)) {
        nodeIds[node] = "node_${nodeCounter++}";
      }
    }

    void buildGraph(GlushList<T> node, StringBuffer buf) {
      if (visited.contains(node)) {
        return;
      }
      visited.add(node);

      generateNodeId(node);
      var nodeId = nodeIds[node]!;

      if (node is EmptyList<T>) {
        buf.writeln('  $nodeId [label="Empty", style="filled", fillcolor="lightgray"];');
      } else if (node is Push<T>) {
        buf.writeln(
          '  $nodeId [label="Push(${_escapeDot(node.data.toString())})", style="filled", fillcolor="lightblue"];',
        );
        generateNodeId(node.parent);
        var parentId = nodeIds[node.parent]!;
        buf.writeln('  $nodeId -> $parentId [label="parent"];');
        buildGraph(node.parent, buf);
      } else if (node is Concat<T>) {
        buf.writeln('  $nodeId [label="Concat", style="filled", fillcolor="lightyellow"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        var leftId = nodeIds[node.left]!;
        var rightId = nodeIds[node.right]!;
        buf.writeln('  $nodeId -> $leftId [label="left"];');
        buf.writeln('  $nodeId -> $rightId [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is Conjunction<T>) {
        buf.writeln('  $nodeId [label="Parallel", style="filled", fillcolor="lightcyan"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        var leftId = nodeIds[node.left]!;
        var rightId = nodeIds[node.right]!;
        buf.writeln('  $nodeId -> $leftId [label="left"];');
        buf.writeln('  $nodeId -> $rightId [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is BranchedList<T>) {
        buf.writeln('  $nodeId [label="Branched", style="filled", fillcolor="lightgreen"];');
        generateNodeId(node.left);
        var leftId = nodeIds[node.left]!;
        buf.writeln('  $nodeId -> $leftId [label="left"];');
        buildGraph(node.left, buf);

        if (node.right != null) {
          generateNodeId(node.right!);
          var rightId = nodeIds[node.right!]!;
          buf.writeln('  $nodeId -> $rightId [label="right"];');
          buildGraph(node.right!, buf);
        }
      }
    }

    buildGraph(this, buffer);
    buffer.writeln("}");
    return buffer.toString();
  }

  /// Escapes special characters for dot format
  String _escapeDot(String label) {
    return label
        .replaceAll(r"\", r"\\")
        .replaceAll('"', r'\"')
        .replaceAll("\n", r"\n")
        .replaceAll("\r", r"\r");
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
    } else if (node is Conjunction<T>) {
      buffer.writeln("Parallel");
      _visualize(node.left, buffer, prefix + (isLast ? "    " : "│   "), false, visited);
      _visualize(node.right, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is BranchedList<T>) {
      buffer.writeln("Branched");
      _visualize(
        node.left,
        buffer,
        prefix + (isLast ? "    " : "│   "),
        node.right == null,
        visited,
      );
      if (node.right != null) {
        _visualize(node.right!, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
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
