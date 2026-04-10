/// Custom list implementation for managing parse alternatives
library glush.list;

import "dart:collection";

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

      if (item is! GlushList) {
        continue;
      }
      var node = item;
      switch (node) {
        case EmptyList():
          break;
        case BranchedList(:var left, :var right):
          if (right != null) {
            stack.add(right);
          }
          stack.add(left);
        case Push(:var parent, :var data):
          stack.add(data);
          stack.add(_dataMarker);
          stack.add(parent);
        case Concat(:var left, :var right):
          stack.add(right);
          stack.add(left);
        case Conjunction(:var left, :var right):
          stack.add(right);
          stack.add(left);
      }
    }
  }

  /// Returns the total number of unique flattened derivations this forest represents.
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
      case Push(:var parent):
        res = _count(parent, memo);
      case Concat(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
      case Conjunction(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
    }
    return memo[node] = res;
  }

  bool get isEmpty;

  T? get lastOrNull {
    if (this case Push<T>(:var data)) {
      return data;
    }
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
      other is BranchedList<T> &&
          _hashCode == other._hashCode &&
          left == other.left &&
          right == other.right;

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

/// Represents parallel marks at the same span from different derivations.
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
      other is Conjunction<T> &&
          _hashCode == other._hashCode &&
          left == other.left &&
          right == other.right;

  @override
  int get hashCode => _hashCode;
}

/// A lazy version of [GlushList] where all operations are thunks.
///
/// This allows building a forest of potential marks without actually
/// evaluating any of the markers until [evaluate] is called.

sealed class LazyGlushList<T> {
  const LazyGlushList();

  const factory LazyGlushList.empty() = LazyEmpty<T>._;

  /// Evaluates the lazy operations and returns a concrete [GlushList].
  ///
  /// Results are memoized to avoid redundant work when sub-forests are shared.
  GlushList<T> evaluate();

  bool get isEmpty;

  /// Wraps an 'add' operation in a thunk.
  LazyGlushList<T> add(LazyVal<T> val) => _LazyInterner.push<T>(this, val);

  /// Wraps a 'concat' operation.
  LazyGlushList<T> addList(LazyGlushList<T> other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return _LazyInterner.concat<T>(this, other);
  }

  /// Wraps a 'branched' operation.
  static LazyGlushList<T> branched<T>(LazyGlushList<T> left, LazyGlushList<T> right) {
    if (identical(left, right)) {
      return left;
    }
    if (left.isEmpty) {
      return right;
    }
    if (right.isEmpty) {
      return left;
    }
    return _LazyInterner.branched<T>(left, right);
  }

  /// Wraps a 'conjunction' operation.
  static LazyGlushList<T> conjunction<T>(LazyGlushList<T> left, LazyGlushList<T> right) {
    if (identical(left, right)) {
      return left;
    }
    if (left.isEmpty && right.isEmpty) {
      return const LazyGlushList.empty();
    }
    if (left.isEmpty) {
      return right;
    }
    if (right.isEmpty) {
      return left;
    }
    return _LazyInterner.conjunction<T>(left, right);
  }

  /// Wraps a Rule Return. Used for lazy span deduplication (SPPF-like).
  static LazyGlushList<T> ruleReturn<T>(
    LazyGlushList<T> Function() provider,
    Object owner,
    int packedId,
  ) => _LazyInterner.ruleReturn<T>(provider, owner, packedId);

  /// Creates a lazy list from a standard Dart list by wrapping each element
  /// in a thunk that returns the pre-existing value.
  static LazyGlushList<T> fromList<T>(List<T> values) {
    LazyGlushList<T> list = LazyGlushList<T>.empty();
    for (var value in values) {
      list = list.add(ConstantLazyVal(value));
    }
    return list;
  }

  int countDerivations() => _count(this, {});

  int _count(LazyGlushList<Object?> node, Map<LazyGlushList<Object?>, int> memo) {
    if (memo[node] case var cached?) {
      return cached;
    }

    memo[node] = 0;
    int res;
    switch (node) {
      case LazyEmpty():
        res = 1;
      case LazyBranched(:var left, :var right):
        res = _count(left, memo) + _count(right, memo);
      case LazyPush(:var parent):
        res = _count(parent, memo);
      case LazyConcat(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
      case LazyConjunction(:var left, :var right):
        res = _count(left, memo) * _count(right, memo);
      case LazyEvaluated<Object?>():
        return node.list.countDerivations();
      case LazyReturn<Object?>():
        return _count(node.provider(), memo);
      case _LazyBase<Object?>():
        // This should be covered by the subclasses above, but needed for exhaustiveness
        // of the sealed class if the compiler is strict about direct subclasses.
        throw UnimplementedError("Unreachable: _LazyBase matched but not its subclasses");
    }
    return memo[node] = res;
  }
}

/// Global cache for interning lazy nodes to ensure A == B iff identical(A, B).
///
/// Uses identity-based (fast) map lookups for LazyGlushList keys since they are
/// already interned—identical trees produce identical object instances.
class _LazyInterner {
  /// Identity-based cache for push operations: parent -> val -> LazyPush
  /// Using HashMap with identical() equality instead of structural ==.
  static final Expando<Map<Object, LazyPush<Object?>>> _push = Expando();

  /// Identity-based cache for branched operations: left -> right -> LazyBranched
  static final Expando<Map<Object, LazyBranched<Object?>>> _branched = Expando();

  /// Identity-based cache for concat operations: left -> right -> LazyConcat
  static final Expando<Map<Object, LazyConcat<Object?>>> _concat = Expando();

  /// Identity-based cache for conjunction operations: left -> right -> LazyConjunction
  static final Expando<Map<Object, LazyConjunction<Object?>>> _conjunction = Expando();

  static LazyGlushList<T> push<T>(LazyGlushList<T> parent, LazyVal<T> val) {
    // For LazyVal, we keep structural equality since ConstantLazyVal needs value comparison.
    // Only the outer Expando lookup is identity-based on parent.
    var parentCache = _push[parent] ??= HashMap.identity();
    return (parentCache[val] ??= LazyPush<T>._(parent, val)) as LazyGlushList<T>;
  }

  static LazyGlushList<T> branched<T>(LazyGlushList<T> left, LazyGlushList<T> right) {
    var leftCache = _branched[left] ??= HashMap.identity();
    return (leftCache[right] ??= LazyBranched<T>._(left, right)) as LazyGlushList<T>;
  }

  static LazyGlushList<T> concat<T>(LazyGlushList<T> left, LazyGlushList<T> right) {
    var leftCache = _concat[left] ??= HashMap.identity();
    return (leftCache[right] ??= LazyConcat<T>._(left, right)) as LazyGlushList<T>;
  }

  static LazyGlushList<T> conjunction<T>(LazyGlushList<T> left, LazyGlushList<T> right) {
    var leftCache = _conjunction[left] ??= HashMap.identity();
    return (leftCache[right] ??= LazyConjunction<T>._(left, right)) as LazyGlushList<T>;
  }

  /// Cache for LazyReturn proxies: owner -> packedId -> LazyReturn
  /// Stores LazyReturn directly by int packedId to avoid boxed-int allocation
  /// and Expando overhead. Since owner (Caller) manages return state by packedId anyway,
  /// this is more efficient than the previous two-level boxed-int approach.
  static final Expando<Map<int, LazyReturn<Object?>>> _returns = Expando();

  static LazyGlushList<T> ruleReturn<T>(
    LazyGlushList<T> Function() provider,
    Object owner,
    int packedId,
  ) {
    var cache = _returns[owner] ??= {};
    // Store LazyReturn directly keyed by int (no boxing), making lookups O(1) without type overhead.
    return (cache[packedId] ??= LazyReturn<T>._(provider)) as LazyGlushList<T>;
  }
}

/// Internal base class for memoized lazy evaluation.
// ignore: must_be_immutable
abstract class _LazyBase<T> extends LazyGlushList<T> {
  _LazyBase();

  @override
  GlushList<T> evaluate() {
    var cached = _evaluated;
    if (cached != null) {
      return cached;
    }
    var result = _evaluate();
    _evaluated = result;
    return result;
  }

  GlushList<T>? _evaluated;

  GlushList<T> _evaluate();
}

class LazyEmpty<T> extends LazyGlushList<T> {
  const LazyEmpty._();

  @override
  GlushList<T> evaluate() => GlushList<T>.empty();

  @override
  bool get isEmpty => true;
}

class LazyPush<T> extends _LazyBase<T> {
  LazyPush._(this.parent, this.val);
  final LazyGlushList<T> parent;
  final LazyVal<T> val;

  @override
  GlushList<T> _evaluate() => parent.evaluate().add(val.evaluate());

  @override
  bool get isEmpty => false;
}

class LazyBranched<T> extends _LazyBase<T> {
  LazyBranched._(this.left, this.right);
  final LazyGlushList<T> left;
  final LazyGlushList<T> right;

  @override
  // Composite nodes are only created by the factory if children are non-empty.
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => GlushList.branched(left.evaluate(), right.evaluate());
}

class LazyConcat<T> extends _LazyBase<T> {
  LazyConcat._(this.left, this.right);
  final LazyGlushList<T> left;
  final LazyGlushList<T> right;

  @override
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => left.evaluate().addList(right.evaluate());
}

class LazyConjunction<T> extends _LazyBase<T> {
  LazyConjunction._(this.left, this.right);
  final LazyGlushList<T> left;
  final LazyGlushList<T> right;

  @override
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => GlushList.conjunction(left.evaluate(), right.evaluate());
}

class LazyReturn<T> extends _LazyBase<T> {
  LazyReturn._(this.provider);
  final LazyGlushList<T> Function() provider;

  @override
  GlushList<T> _evaluate() => provider().evaluate();

  @override
  // Rule returns are treated as non-empty to avoid recursive isEmpty checks during
  // forest construction. Epsilon matches still work correctly as evaluate()
  // will eventually return an EmptyList.
  bool get isEmpty => false;
}

/// Represents a deferred value creation with structural equality.
abstract class LazyVal<T> {
  const LazyVal();
  T evaluate();

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

/// A [LazyVal] that simply returns a pre-existing constant value.
class ConstantLazyVal<T> extends LazyVal<T> {
  const ConstantLazyVal(this.value);
  final T value;

  @override
  T evaluate() => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ConstantLazyVal<T> && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toString();
}

/// A [LazyVal] that wraps a closure. Identity is based on the closure instance.
class ClosureVal<T> extends LazyVal<T> {
  const ClosureVal(this.thunk);
  final T Function() thunk;

  @override
  T evaluate() => thunk();

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(thunk);
}

/// A lazy node wrapping an already evaluated [GlushList].
class LazyEvaluated<T> extends LazyGlushList<T> {
  const LazyEvaluated(this.list);
  final GlushList<T> list;

  @override
  GlushList<T> evaluate() => list;

  @override
  bool get isEmpty => list.isEmpty;
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
        for (var l in _collect(node.left, visiting)) {
          for (var r in _collect(node.right, visiting)) {
            yield [...l, ...r];
          }
        }
      case Conjunction<T>():
        if (T == Mark || T.toString().contains("Mark")) {
          for (var leftPath in _collect(node.left, visiting)) {
            for (var rightPath in _collect(node.right, visiting)) {
              var leftList = LazyGlushList.fromList(leftPath.cast<Mark>());
              var rightList = LazyGlushList.fromList(rightPath.cast<Mark>());
              yield [ConjunctionMark(leftList, rightList, 0) as T];
            }
          }
        } else {
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
      if (node is EmptyList<T> || visited.contains(node)) {
        return;
      }
      visited.add(node);
      generateNodeId(node);
      var nodeId = nodeIds[node]!;
      if (node is Push<T>) {
        buf.writeln(
          '  $nodeId [label="Push(${_escapeDot(node.data.toString())})", style="filled", fillcolor="lightblue"];',
        );
        generateNodeId(node.parent);
        if (!node.parent.isEmpty) {
          buf.writeln('  $nodeId -> ${nodeIds[node.parent]!} [label="parent"];');
        }
        buildGraph(node.parent, buf);
      } else if (node is Concat<T>) {
        buf.writeln('  $nodeId [label="Concat", style="filled", fillcolor="lightyellow"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buf.writeln('  $nodeId -> ${nodeIds[node.right]!} [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is Conjunction<T>) {
        buf.writeln('  $nodeId [label="Parallel", style="filled", fillcolor="lightcyan"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buf.writeln('  $nodeId -> ${nodeIds[node.right]!} [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is BranchedList<T>) {
        buf.writeln('  $nodeId [label="Branched", style="filled", fillcolor="lightgreen"];');
        generateNodeId(node.left);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buildGraph(node.left, buf);
        if (node.right != null) {
          generateNodeId(node.right!);
          buf.writeln('  $nodeId -> ${nodeIds[node.right!]!} [label="right"];');
          buildGraph(node.right!, buf);
        }
      }
    }

    buildGraph(this, buffer);
    buffer.writeln("}");
    return buffer.toString();
  }

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

extension LazyGlushListVisualizer<T> on LazyGlushList<T> {
  static final Expando<List<List<Object?>>> _pathCache = Expando();

  Iterable<List<T>> allPaths() {
    return _collectLazy(this, const {});
  }

  Iterable<List<T>> _collectLazy(LazyGlushList<T> node, Set<LazyGlushList<T>> stack) {
    if (stack.contains(node)) {
      return const [];
    }

    // Memoization: if we already computed paths for this node (outside of any cycle), reuse them.
    // Note: we can only memoize if the stack is empty or won't affect the result.
    // For simplicity, we only memoize nodes that are fully explored.
    var cached = _pathCache[node];
    if (cached != null) {
      return cached.cast<List<T>>();
    }

    var results = <List<T>>[];
    var newStack = {...stack, node};

    if (node is LazyEmpty<T>) {
      results.add(const []);
    } else if (node is LazyPush<T>) {
      for (var pPath in _collectLazy(node.parent, newStack)) {
        results.add([...pPath, node.val.evaluate()]);
      }
    } else if (node is LazyBranched<T>) {
      results.addAll(_collectLazy(node.left, newStack));
      results.addAll(_collectLazy(node.right, newStack));
    } else if (node is LazyConcat<T>) {
      for (var l in _collectLazy(node.left, newStack)) {
        for (var r in _collectLazy(node.right, newStack)) {
          results.add([...l, ...r]);
        }
      }
    } else if (node is LazyConjunction<T>) {
      if (T == Mark || T.toString().contains("Mark")) {
        for (var leftPath in _collectLazy(node.left, newStack)) {
          for (var rightPath in _collectLazy(node.right, newStack)) {
            var leftList = LazyGlushList.fromList(leftPath.cast<Mark>());
            var rightList = LazyGlushList.fromList(rightPath.cast<Mark>());
            results.add([ConjunctionMark(leftList, rightList, 0) as T]);
          }
        }
      } else {
        for (var l in _collectLazy(node.left, newStack)) {
          for (var r in _collectLazy(node.right, newStack)) {
            results.add([...l, ...r]);
          }
        }
      }
    } else if (node is LazyEvaluated<T>) {
      results.addAll(node.list.allPaths());
    } else if (node is LazyReturn<T>) {
      results.addAll(_collectLazy(node.provider(), newStack));
    }

    if (stack.isEmpty) {
      _pathCache[node] = results;
    }
    return results;
  }

  String visualize() {
    var buffer = StringBuffer();
    _visualizeLazy(this, buffer, "", true, {});
    return buffer.toString();
  }

  void _visualizeLazy(
    LazyGlushList<T> node,
    StringBuffer buffer,
    String prefix,
    bool isLast,
    Set<LazyGlushList<T>> visited,
  ) {
    var connector = isLast ? "└── " : "├── ";
    buffer.write(prefix);
    buffer.write(connector);
    if (visited.contains(node)) {
      buffer.writeln("(lazy shared ...)");
      return;
    }
    visited.add(node);

    if (node is LazyEmpty<T>) {
      buffer.writeln("LazyEmpty");
    } else if (node is LazyPush<T>) {
      buffer.writeln("LazyPush(thunk)");
      _visualizeLazy(node.parent, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is LazyBranched<T>) {
      buffer.writeln("LazyBranched");
      _visualizeLazy(node.left, buffer, prefix + (isLast ? "    " : "│   "), false, visited);
      _visualizeLazy(node.right, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is LazyConcat<T>) {
      buffer.writeln("LazyConcat");
      _visualizeLazy(node.left, buffer, prefix + (isLast ? "    " : "│   "), false, visited);
      _visualizeLazy(node.right, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is LazyConjunction<T>) {
      buffer.writeln("LazyParallel");
      _visualizeLazy(node.left, buffer, prefix + (isLast ? "    " : "│   "), false, visited);
      _visualizeLazy(node.right, buffer, prefix + (isLast ? "    " : "│   "), true, visited);
    } else if (node is LazyEvaluated<T>) {
      buffer.writeln("LazyEvaluated");
    }
  }

  String toDot() {
    var buffer = StringBuffer();
    buffer.writeln("digraph G {");
    var nodeIds = <LazyGlushList<T>, String>{};
    var idCounter = 0;

    void generateNodeId(LazyGlushList<T> node) {
      if (!nodeIds.containsKey(node)) {
        nodeIds[node] = "ln${idCounter++}";
      }
    }

    var visited = <LazyGlushList<T>>{};

    void buildGraph(LazyGlushList<T> node, StringBuffer buf) {
      if (node is LazyEmpty<T> || visited.contains(node)) {
        return;
      }
      visited.add(node);
      generateNodeId(node);
      var nodeId = nodeIds[node]!;

      if (node is LazyPush<T>) {
        buf.writeln('  $nodeId [label="LazyPush(thunk)", style="filled", fillcolor="lightblue"];');
        generateNodeId(node.parent);
        buf.writeln('  $nodeId -> ${nodeIds[node.parent]!} [label="parent"];');
        buildGraph(node.parent, buf);
      } else if (node is LazyConcat<T>) {
        buf.writeln('  $nodeId [label="LazyConcat", style="filled", fillcolor="lightyellow"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buf.writeln('  $nodeId -> ${nodeIds[node.right]!} [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is LazyConjunction<T>) {
        buf.writeln('  $nodeId [label="LazyParallel", style="filled", fillcolor="lightcyan"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buf.writeln('  $nodeId -> ${nodeIds[node.right]!} [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is LazyBranched<T>) {
        buf.writeln('  $nodeId [label="LazyBranched", style="filled", fillcolor="lightgreen"];');
        generateNodeId(node.left);
        generateNodeId(node.right);
        buf.writeln('  $nodeId -> ${nodeIds[node.left]!} [label="left"];');
        buf.writeln('  $nodeId -> ${nodeIds[node.right]!} [label="right"];');
        buildGraph(node.left, buf);
        buildGraph(node.right, buf);
      } else if (node is LazyEvaluated<T>) {
        buf.writeln('  $nodeId [label="LazyEvaluated", style="filled", fillcolor="gray"];');
      }
    }

    buildGraph(this, buffer);
    buffer.writeln("}");
    return buffer.toString();
  }
}
