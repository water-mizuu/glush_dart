/// Custom list implementation for managing parse alternatives
library glush.list;

import "package:glush/src/helper/diagonal.dart";
import "package:meta/meta.dart";

/// Abstract base class for managing parse alternatives as a tree structure.
///
/// [GlushList] provides an efficient way to represent multiple parsing results
/// without flattening them into a single list. It uses a tree-like composition
/// pattern where results can be combined, branched, and ultimately converted
/// to a flat list when needed. This structure is particularly effective for
/// handling ambiguous grammars where many different parse trees might share
/// common sub-structures.
@immutable
sealed class GlushList<T> {
  /// Base constructor for [GlushList].
  const GlushList();

  /// A constant factory that returns an instance of an empty [GlushList].
  ///
  /// Using a dedicated [EmptyList] type allows for efficient identity-based
  /// checks and avoids unnecessary allocations when representing empty results.
  const factory GlushList.empty() = EmptyList<T>._;

  /// Creates a branched list representing multiple parsing alternatives.
  ///
  /// This factory is used when the parser encounters multiple valid paths
  /// (ambiguity). Instead of duplicating the common prefix, it creates a
  /// [BranchedList] that points to both alternatives. It includes optimization
  /// logic to avoid redundant branching if one side is empty or if both sides
  /// are identical.
  factory GlushList.branched(GlushList<T> left, GlushList<T> right) {
    if (left.isEmpty) {
      return right;
    }

    if (right.isEmpty) {
      return left;
    }

    // Identity-based dedup avoids recursive structural comparison.
    if (identical(left, right)) {
      return left;
    }

    return BranchedList<T>._(left, right);
  }

  /// Creates a [GlushList] from a standard Dart list.
  ///
  /// This utility method iterates through the provided values and builds up
  /// a linear [GlushList] by repeatedly calling [add]. It is useful for
  /// bootstrapping a mark forest from a known set of tokens.
  static GlushList<T> fromList<T>(List<T> values) {
    GlushList<T> list = GlushList<T>.empty();
    for (var value in values) {
      list = list.add(value);
    }
    return list;
  }

  /// Appends a single item to the end of the list.
  ///
  /// This operation creates a [Push] node, which effectively represents a
  /// link back to the current list plus the new data. This allows for
  /// persistent, immutable growth of the mark stream.
  GlushList<T> add(T data) => Push<T>._(this, data);

  /// Concatenates another [GlushList] to this one.
  ///
  /// This method uses a [Concat] node to logically join two forests. It includes
  /// fast-path optimizations for cases where either list is empty, ensuring
  /// that the resulting structure remains as compact as possible.
  GlushList<T> addList(GlushList<T> list) => switch ((this, list)) {
    (EmptyList(), var r) => r,
    (var l, EmptyList()) => l,
    _ => Concat<T>._(this, list),
  };

  /// Creates a parallel combination (conjunction) of two mark forests.
  ///
  /// In Glush, a conjunction requires both branches to match the same input range.
  /// This method creates a [Conjunction] node that stores both result streams.
  /// It optimizes away empty branches to prevent unnecessary structural nesting.
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

  /// Internal marker used to signal that the next item on the stack is raw data.
  static final Object _dataMarker = Object();

  /// Provides an iterative depth-first traversal of the flattened list contents.
  ///
  /// This method yields each element in the forest in the order they were
  /// logically added. It uses an internal stack and a marker system to
  /// perform the traversal without deep recursion, which avoids stack overflow
  /// issues on extremely deep or complex parse trees.
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
  ///
  /// This property provides a high-level metric of the ambiguity present in
  /// the parse result. It is computed lazily and memoized for efficiency.
  int get derivationCount {
    return _count(this, {});
  }

  /// Alias for [derivationCount] implemented as a method.
  int countDerivations() => _count(this, {});

  /// Internal recursive counter with memoization to compute the number of derivations.
  ///
  /// The algorithm branches for [BranchedList] (addition) and multiplies for
  /// [Concat] and [Conjunction] to account for all possible combinations of
  /// sub-parse results.
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

  /// Whether this list represents an empty result set.
  bool get isEmpty;

  /// Returns the last element added to the list, or null if the list is empty.
  ///
  /// This is optimized for [Push] nodes to avoid a full traversal of the forest.
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

/// An implementation of [GlushList] that contains no elements.
class EmptyList<T> extends GlushList<T> {
  /// Internal constructor for the empty list singleton.
  const EmptyList._();

  @override
  bool get isEmpty => true;
}

/// A [GlushList] node representing a choice between two alternative forests.
class BranchedList<T> extends GlushList<T> {
  /// Internal constructor for a branched result.
  BranchedList._(this.left, [this.right]) : _isEmpty = left.isEmpty && (right?.isEmpty ?? true);

  /// The first alternative forest.
  final GlushList<T> left;

  /// The optional second alternative forest.
  final GlushList<T>? right;

  /// Pre-computed empty status for efficiency.
  final bool _isEmpty;

  @override
  bool get isEmpty => _isEmpty;
}

/// A [GlushList] node representing the addition of a single element to a parent forest.
class Push<T> extends GlushList<T> {
  /// Internal constructor for a push operation.
  const Push._(this.parent, this.data) : _lastOrNull = data;

  /// The parent forest to which this element is appended.
  final GlushList<T> parent;

  /// The data element being added.
  final T data;

  /// Cached last element for fast access.
  final T? _lastOrNull;

  @override
  T? get lastOrNull => _lastOrNull;

  @override
  bool get isEmpty => false;
}

/// A [GlushList] node representing the sequential concatenation of two forests.
class Concat<T> extends GlushList<T> {
  /// Internal constructor for a concatenation.
  const Concat._(this.left, this.right);

  /// The prefix forest.
  final GlushList<T> left;

  /// The suffix forest.
  final GlushList<T> right;

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;
}

/// A [GlushList] node representing parallel marks from different branches of a conjunction.
///
/// This structure is used to preserve the distinct derivation paths that
/// simultaneously matched the same input span.
class Conjunction<T> extends GlushList<T> {
  /// Internal constructor for a conjunction.
  const Conjunction._(this.left, this.right);

  /// The marks from the left branch.
  final GlushList<T> left;

  /// The marks from the right branch.
  final GlushList<T> right;

  @override
  bool get isEmpty => left.isEmpty && right.isEmpty;
}

/// A lazy version of [GlushList] where all operations are thunks.
///
/// This allows building a forest of potential marks without actually
/// evaluating any of the markers until [evaluate] is called. Deferring
/// evaluation is a key optimization in Glush that allows the parser to
/// explore many paths without paying the price of object creation for
/// results that might later be pruned.
sealed class LazyGlushList<T> {
  /// Base constructor for [LazyGlushList].
  const LazyGlushList();

  /// A constant factory for an empty lazy list.
  const factory LazyGlushList.empty() = LazyEmpty<T>._;

  /// Evaluates the lazy operations and returns a concrete [GlushList].
  ///
  /// Results are memoized to avoid redundant work when sub-forests are shared
  /// across different branches of the parse.
  GlushList<T> evaluate();

  /// Whether this lazy list is fundamentally empty.
  bool get isEmpty;

  /// Wraps an 'add' operation in a thunk.
  ///
  /// The [val] is a [LazyVal] that will be evaluated only when this list
  /// itself is evaluated.
  LazyGlushList<T> add(LazyVal<T> val) => LazyPush<T>._(this, val);

  /// Wraps a 'concat' operation in a thunk.
  ///
  /// This joins two lazy forests sequentially. It includes optimizations to
  /// bypass empty lists.
  LazyGlushList<T> addList(LazyGlushList<T> other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return LazyConcat<T>._(this, other);
  }

  /// Wraps a 'branched' operation in a thunk.
  ///
  /// This creates a lazy choice between two alternative forests, performing
  /// identity and emptiness checks to keep the structure compact.
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
    return LazyBranched._(left, right);
  }

  /// Wraps a 'conjunction' operation in a thunk.
  ///
  /// This lazily combines two results that matched the same span in a
  /// conjunction pattern.
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
    return LazyConjunction._(left, right);
  }

  /// Creates a lazy list from a standard Dart list.
  ///
  /// This wraps each element in a [ConstantLazyVal], allowing pre-existing
  /// data to be integrated into the lazy mark stream system.
  static LazyGlushList<T> fromList<T>(List<T> values) {
    LazyGlushList<T> list = LazyGlushList<T>.empty();
    for (var value in values) {
      list = list.add(ConstantLazyVal(value));
    }
    return list;
  }

  /// Computes the number of derivations represented by this lazy forest.
  int countDerivations() => _count(this, {});

  /// Internal recursive counter for lazy derivations.
  ///
  /// This traverses the lazy structure and accounts for branching and
  /// multiplication in a manner similar to the concrete [GlushList] counter.
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
        res = node.list.countDerivations();
      case LazyReturn<Object?>():
        res = _count(node.provider(), memo);
    }
    return memo[node] = res;
  }
}

/// Internal base class for memoized lazy evaluation.
///
/// This class handles the caching of evaluation results to ensure that
/// each node in the lazy forest is only processed once.
// ignore: must_be_immutable
sealed class _LazyBase<T> extends LazyGlushList<T> {
  /// Base constructor for internal lazy nodes.
  _LazyBase();

  /// Public evaluation entry point that uses the internal cache.
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

  /// The cached result of evaluation, if any.
  GlushList<T>? _evaluated;

  /// Internal method to perform the actual evaluation logic for a specific node type.
  GlushList<T> _evaluate();
}

/// A lazy representation of an empty list.
class LazyEmpty<T> extends LazyGlushList<T> {
  /// Internal constructor for the empty lazy list singleton.
  const LazyEmpty._();

  @override
  GlushList<T> evaluate() => GlushList<T>.empty();

  @override
  bool get isEmpty => true;
}

/// A lazy node representing a push operation.
class LazyPush<T> extends _LazyBase<T> {
  /// Internal constructor for a lazy push.
  LazyPush._(this.parent, this.val);

  /// The parent lazy list.
  final LazyGlushList<T> parent;

  /// The lazy value to be pushed.
  final LazyVal<T> val;

  @override
  GlushList<T> _evaluate() => parent.evaluate().add(val.evaluate());

  @override
  bool get isEmpty => false;
}

/// A lazy node representing a choice between two alternative lazy forests.
class LazyBranched<T> extends _LazyBase<T> {
  /// Internal constructor for a lazy branch.
  LazyBranched._(this.left, this.right);

  /// The left alternative.
  final LazyGlushList<T> left;

  /// The right alternative.
  final LazyGlushList<T> right;

  @override
  // Composite nodes are only created by the factory if children are non-empty.
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => GlushList.branched(left.evaluate(), right.evaluate());
}

/// A lazy node representing the concatenation of two lazy forests.
class LazyConcat<T> extends _LazyBase<T> {
  /// Internal constructor for a lazy concatenation.
  LazyConcat._(this.left, this.right);

  /// The prefix lazy forest.
  final LazyGlushList<T> left;

  /// The suffix lazy forest.
  final LazyGlushList<T> right;

  @override
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => left.evaluate().addList(right.evaluate());
}

/// A lazy node representing a conjunction of two lazy forests.
class LazyConjunction<T> extends _LazyBase<T> {
  /// Internal constructor for a lazy conjunction.
  LazyConjunction._(this.left, this.right);

  /// The left branch results.
  final LazyGlushList<T> left;

  /// The right branch results.
  final LazyGlushList<T> right;

  @override
  bool get isEmpty => false;

  @override
  GlushList<T> _evaluate() => GlushList.conjunction(left.evaluate(), right.evaluate());
}

/// A lazy node that delegates its evaluation to a provider function.
///
/// This is used to handle recursive rules by deferring the lookup of the
/// rule's result forest until evaluation time.
class LazyReturn<T> extends _LazyBase<T> {
  /// Creates a [LazyReturn] with the given [provider].
  LazyReturn(this.provider);

  /// A function that returns the actual [LazyGlushList] to be evaluated.
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
///
/// Subclasses implement [evaluate] to produce the final value only when requested.
abstract class LazyVal<T> {
  /// Base constructor for [LazyVal].
  const LazyVal();

  /// Produces the final value of type [T].
  T evaluate();
}

/// A [LazyVal] that simply returns a pre-existing constant value.
class ConstantLazyVal<T> extends LazyVal<T> {
  /// Creates a [ConstantLazyVal] wrapping the given [value].
  const ConstantLazyVal(this.value);

  /// The pre-existing value to return.
  final T value;

  /// Returns the wrapped value.
  @override
  T evaluate() => value;

  /// Returns the string representation of the value.
  @override
  String toString() => value.toString();
}

/// A [LazyVal] that wraps a closure. Identity is based on the closure instance.
class ClosureVal<T> extends LazyVal<T> {
  /// Creates a [ClosureVal] wrapping the given [thunk].
  const ClosureVal(this.thunk);

  /// The closure to execute during evaluation.
  final T Function() thunk;

  /// Executes the thunk and returns its result.
  @override
  T evaluate() => thunk();
}

/// A lazy node wrapping an already evaluated [GlushList].
class LazyEvaluated<T> extends LazyGlushList<T> {
  /// Creates a [LazyEvaluated] node wrapping the given concrete [list].
  const LazyEvaluated(this.list);

  /// The concrete [GlushList] that was previously evaluated.
  final GlushList<T> list;

  /// Returns the wrapped list.
  @override
  GlushList<T> evaluate() => list;

  @override
  bool get isEmpty => list.isEmpty;
}

/// Extensions for visualizing and exploring [GlushList] structures.
extension GlushListVisualizer<T> on GlushList<T> {
  /// Generates all possible flattened paths (derivations) through the forest.
  ///
  /// This is an exhaustive search that yields every possible linear sequence
  /// of marks represented by the compressed forest structure.
  Iterable<List<T>> allMarkPaths() {
    return _collect(this, {});
  }

  /// Internal recursive collector for generating all paths.
  ///
  /// This handles branching, concatenation, and conjunction by combining
  /// sub-paths from children. [diagonalize] is used for combinatoric structures
  /// to ensure efficient path generation.
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
        for (var (l, r) in diagonalize(
          _collect(node.left, visiting),
          _collect(node.right, visiting),
        )) {
          yield [...l, ...r];
        }
      case Conjunction<T>():
        for (var (l, r) in diagonalize(
          _collect(node.left, visiting),
          _collect(node.right, visiting),
        )) {
          yield [...l, ...r];
        }
    }
  }

  /// Generates a Graphviz DOT representation of the forest structure.
  ///
  /// This provides a visual way to inspect the internal nodes and connections
  /// of the compressed forest, which is invaluable for debugging complex
  /// grammars and ensuring correct sharing of sub-structures.
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

  /// Escapes special characters for use in Graphviz labels.
  String _escapeDot(String label) {
    return label
        .replaceAll(r"\", r"\\")
        .replaceAll('"', r'\"')
        .replaceAll("\n", r"\n")
        .replaceAll("\r", r"\r");
  }
}

/// Extensions for visualizing and exploring [LazyGlushList] structures.
extension LazyGlushListVisualizer<T> on LazyGlushList<T> {
  /// Internal cache for memoizing path generation results.
  static final Expando<List<List<Object?>>> _pathCache = Expando();

  /// Generates all possible flattened paths through the lazy forest.
  Iterable<List<T>> allMarkPaths() {
    return _collectLazy(this, const {});
  }

  /// Internal recursive collector for lazy paths with cycle detection.
  Iterable<List<T>> _collectLazy(LazyGlushList<T> node, Set<int> stack) {
    if (stack.contains(node.hashCode)) {
      return const [];
    }

    // Memoization: if we already computed paths for this node (outside of any cycle), reuse them.
    var cached = _pathCache[node];
    if (cached != null) {
      return cached.cast<List<T>>();
    }

    var results = <List<T>>[];
    var newStack = {...stack, node.hashCode};

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
      for (var (l, r) in diagonalize(
        _collectLazy(node.left, newStack),
        _collectLazy(node.right, newStack),
      )) {
        results.add([...l, ...r]);
      }
    } else if (node is LazyConjunction<T>) {
      for (var (l, r) in diagonalize(
        _collectLazy(node.left, newStack),
        _collectLazy(node.right, newStack),
      )) {
        results.add([...l, ...r]);
      }
    } else if (node is LazyEvaluated<T>) {
      results.addAll(node.list.allMarkPaths());
    } else if (node is LazyReturn<T>) {
      results.addAll(_collectLazy(node.provider(), newStack));
    }

    if (stack.isEmpty) {
      _pathCache[node] = results;
    }
    return results;
  }

  /// Generates a Graphviz DOT representation of the lazy forest.
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
