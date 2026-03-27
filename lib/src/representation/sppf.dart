/// Shared Packed Parse Forest (SPPF) implementation
library glush.sppf;

import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart" show PatternSymbol;
import "package:glush/src/core/profiling.dart";
import "package:meta/meta.dart";

/// Base class for all forest nodes
@immutable
sealed class ForestNode {
  const ForestNode(this.start, this.end, this.symbol);
  final PatternSymbol symbol;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForestNode &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          symbol == other.symbol;

  @override
  int get hashCode => start.hashCode ^ end.hashCode ^ symbol.hashCode;
}

/// Terminal node (matches a token)
class TerminalNode extends ForestNode {
  const TerminalNode(super.start, super.end, super.symbol, this.token);
  final int token;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is TerminalNode && token == other.token;

  @override
  int get hashCode => super.hashCode ^ token.hashCode;

  @override
  String toString() => "Terminal($token, [$start, $end))";
}

/// Marker node (for named positions / @mark identifiers)
class MarkerNode extends ForestNode {
  const MarkerNode(int position, PatternSymbol symbol, this.name)
    : super(position, position, symbol);
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is MarkerNode && name == other.name;

  @override
  int get hashCode => super.hashCode ^ name.hashCode;

  @override
  String toString() => "Marker(\$name)[$start]";
}

/// Symbolic node (non-terminal)
class SymbolicNode extends ForestNode {
  SymbolicNode(super.start, super.end, super.symbol) : families = {};
  final Set<Family> families;

  void addFamily(Family family) {
    families.add(family);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is SymbolicNode && symbol == other.symbol;

  @override
  int get hashCode => super.hashCode ^ symbol.hashCode;

  @override
  String toString() => "$symbol[$start:$end]";
}

/// Intermediate node (represents semantic actions on children)
class IntermediateNode extends ForestNode {
  IntermediateNode(super.start, super.end, super.symbol) : families = {};
  final Set<Family> families;

  void addFamily(Family family) {
    families.add(family);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      super == other &&
          other is IntermediateNode &&
          families.difference(other.families).isEmpty &&
          families.length == other.families.length;

  @override
  int get hashCode => super.hashCode ^ families.hashCode;

  @override
  String toString() => "Intermediate($symbol, [$start, $end))";
}

/// Family of parse derivations (alternatives)
@immutable
sealed class Family {
  const Family([this.marks = const []]);
  const factory Family.epsilon([List<Mark> marks]) = _EpsilonFamily;
  const factory Family.unary(ForestNode child, [List<Mark> marks]) = _UnaryFamily;
  const factory Family.binary(ForestNode left, ForestNode right, [List<Mark> marks]) =
      _BinaryFamily;
  final List<Mark> marks;

  Iterable<ForestNode> get children sync* {
    switch (this) {
      case _EpsilonFamily _:
        break;
      case _UnaryFamily self:
        yield self.child;
      case _BinaryFamily self:
        yield self.left;
        yield self.right;
    }
  }
}

class _EpsilonFamily extends Family {
  const _EpsilonFamily([super.marks]);

  @override
  bool operator ==(Object other) => identical(this, other) || other is _EpsilonFamily;

  @override
  int get hashCode => marks.hashCode;
}

/// Single child — terminal, or a rule wrapping one sub-pattern
class _UnaryFamily extends Family {
  const _UnaryFamily(this.child, [super.marks]);
  final ForestNode child;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _UnaryFamily && child == other.child;

  @override
  int get hashCode => child.hashCode;
}

/// Binary Seq(left, right) — the normal case
class _BinaryFamily extends Family {
  const _BinaryFamily(this.left, this.right, [super.marks]);
  final ForestNode left;
  final ForestNode right;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BinaryFamily && left == other.left && right == other.right;

  @override
  int get hashCode => left.hashCode ^ right.hashCode;
}

/// Epsilon node (empty parse)
class EpsilonNode extends ForestNode {
  const EpsilonNode(int position, PatternSymbol symbol) : super(position, position, symbol);

  @override
  String toString() => "ε[$start]";
}

/// Forest node cache (deduplicates and caches nodes)
class ForestNodeCache {
  final Map<(int, int, int, PatternSymbol), ForestNode> _nodeCache = {};
  final Set<SymbolicNode> _symbolicNodes = {};
  final Set<TerminalNode> _terminalNodes = {};
  final Set<IntermediateNode> _intermediateNodes = {};
  final Set<MarkerNode> _markerNodes = {};

  (int, int, int, PatternSymbol) _makeCacheKey(
    int typeTag,
    int start,
    int end,
    PatternSymbol symbol,
  ) {
    return (typeTag, start, end, symbol);
  }

  /// Get or create a terminal node
  TerminalNode terminal(int start, int end, PatternSymbol symbol, int token) {
    var key = _makeCacheKey(1, start, end, symbol);
    var cached = _nodeCache[key];
    assert(
      cached == null || cached is TerminalNode,
      "Invariant violation in ForestNodeCache.terminal: cache key reused by "
      "non-terminal node type (${cached.runtimeType}).",
    );
    if (_nodeCache[key] case TerminalNode node) {
      return node;
    }
    var node = TerminalNode(start, end, symbol, token);
    _nodeCache[key] = node;
    _terminalNodes.add(node);
    return node;
  }

  /// Get or create a symbolic node
  SymbolicNode symbolic(int start, int end, PatternSymbol symbol) {
    var key = _makeCacheKey(2, start, end, symbol);
    var cached = _nodeCache[key];
    assert(
      cached == null || cached is SymbolicNode,
      "Invariant violation in ForestNodeCache.symbolic: cache key reused by "
      "different node type (${cached.runtimeType}).",
    );
    if (_nodeCache[key] case SymbolicNode node) {
      return node;
    }
    var node = SymbolicNode(start, end, symbol);
    _nodeCache[key] = node;
    _symbolicNodes.add(node);
    return node;
  }

  /// Get or create an intermediate node
  IntermediateNode intermediate(int start, int end, PatternSymbol symbol) {
    var key = _makeCacheKey(3, start, end, symbol);
    var cached = _nodeCache[key];
    assert(
      cached == null || cached is IntermediateNode,
      "Invariant violation in ForestNodeCache.intermediate: cache key reused "
      "by different node type (${cached.runtimeType}).",
    );
    if (_nodeCache[key] case IntermediateNode node) {
      return node;
    }
    var node = IntermediateNode(start, end, symbol);
    _nodeCache[key] = node;
    _intermediateNodes.add(node);
    return node;
  }

  /// Get or create an epsilon node
  EpsilonNode epsilon(int position, PatternSymbol symbol) {
    var key = _makeCacheKey(4, position, position, symbol);
    var cached = _nodeCache[key];
    assert(
      cached == null || cached is EpsilonNode,
      "Invariant violation in ForestNodeCache.epsilon: cache key reused by "
      "different node type (${cached.runtimeType}).",
    );
    if (_nodeCache[key] case EpsilonNode node) {
      return node;
    }
    var node = EpsilonNode(position, symbol);
    _nodeCache[key] = node;
    return node;
  }

  /// Get or create a marker node
  MarkerNode marker(int position, PatternSymbol symbol, String name) {
    var key = _makeCacheKey(5, position, position, symbol);
    var cached = _nodeCache[key];
    assert(
      cached == null || cached is MarkerNode,
      "Invariant violation in ForestNodeCache.marker: cache key reused by "
      "different node type (${cached.runtimeType}).",
    );
    if (_nodeCache[key] case MarkerNode node) {
      return node;
    }
    var node = MarkerNode(position, symbol, name);
    _nodeCache[key] = node;
    _markerNodes.add(node);
    return node;
  }

  Set<SymbolicNode> get symbolicNodes => _symbolicNodes;
  Set<TerminalNode> get terminalNodes => _terminalNodes;
  Set<IntermediateNode> get intermediateNodes => _intermediateNodes;
  Set<MarkerNode> get markerNodes => _markerNodes;
}

/// Parse forest representation
class ParseForest {
  const ParseForest(this.nodeCache, this.root);
  final ForestNodeCache nodeCache;
  final SymbolicNode root;

  /// Count total nodes in the forest
  int countNodes() {
    var visited = <ForestNode>{};
    _countNodesRecursive(root, visited);
    return visited.length;
  }

  void _countNodesRecursive(ForestNode node, Set<ForestNode> visited) {
    if (visited.contains(node)) {
      return;
    }
    visited.add(node);

    if (node is SymbolicNode) {
      for (var family in node.families) {
        for (var child in family.children) {
          _countNodesRecursive(child, visited);
        }
      }
    } else if (node is IntermediateNode) {
      for (var family in node.families) {
        for (var child in family.children) {
          _countNodesRecursive(child, visited);
        }
      }
    }
  }

  /// Count total families (derivations) in the forest
  int countFamilies() {
    var visited = <ForestNode>{};
    return _countFamiliesRecursive(root, visited);
  }

  int _countFamiliesRecursive(ForestNode node, Set<ForestNode> visited) {
    if (visited.contains(node)) {
      return 0;
    }

    visited.add(node);

    int count = 0;
    if (node case SymbolicNode(:var families) || IntermediateNode(:var families)) {
      count = families.length;
      for (var family in families) {
        for (var child in family.children) {
          count += _countFamiliesRecursive(child, visited);
        }
      }
    }
    return count;
  }

  /// Count derivations using SCC (Strongly Connected Components) analysis.
  /// This is more efficient than enumeration for large forests by:
  /// 1. Identifying shared structure and cycles
  /// 2. Computing derivation counts via dynamic programming
  /// 3. Detecting potentially infinite derivations
  ///
  /// Returns a map with:
  /// - 'count': total number of derivations
  /// - 'hasCycles': whether the forest has cycles (left-recursion)
  /// - 'sccs': number of strongly connected components
  Map<String, Object?> countDerivations() {
    var sccs = _findSCCs();
    var sccMap = <ForestNode, int>{};

    // Map each node to its SCC id
    for (int i = 0; i < sccs.length; i++) {
      for (var node in sccs[i]) {
        sccMap[node] = i;
      }
    }

    // Check for cycles: if any SCC has more than one node, or if a node reaches itself
    bool hasCycles = sccs.any((scc) => scc.length > 1);

    // Count derivations using memoization
    var memo = <ForestNode, BigInt>{};
    var inProgress = <ForestNode>{};

    var count = _countDerivationsDP(root, memo, inProgress, sccMap);

    return {
      "count": count,
      "hasCycles": hasCycles,
      "sccs": sccs.length,
      "forestSize": countNodes(),
    };
  }

  /// Find strongly connected components using Tarjan's algorithm
  List<Set<ForestNode>> _findSCCs() {
    int index = 0;
    var stack = <ForestNode>[];
    var indices = <ForestNode, int>{};
    var lowlinks = <ForestNode, int>{};
    var onStack = <ForestNode, bool>{};
    var sccs = <Set<ForestNode>>[];

    void strongConnect(ForestNode node) {
      indices[node] = index;
      lowlinks[node] = index;
      index++;
      stack.add(node);
      onStack[node] = true;

      // Collect all successors (children) of this node
      var successors = _getSuccessors(node);

      for (var successor in successors) {
        if (!indices.containsKey(successor)) {
          strongConnect(successor);
          lowlinks[node] = (lowlinks[node]! < lowlinks[successor]!)
              ? lowlinks[node]!
              : lowlinks[successor]!;
        } else if (onStack[successor] == true) {
          lowlinks[node] = (lowlinks[node]! < indices[successor]!)
              ? lowlinks[node]!
              : indices[successor]!;
        }
      }

      if (lowlinks[node] == indices[node]) {
        var scc = <ForestNode>{};
        late ForestNode successor;
        do {
          successor = stack.removeLast();
          onStack[successor] = false;
          scc.add(successor);
        } while (successor != node);
        sccs.add(scc);
      }
    }

    // Run Tarjan's algorithm on all nodes
    var allNodes = <ForestNode>{};
    _collectAllNodes(root, allNodes);

    for (var node in allNodes) {
      if (!indices.containsKey(node)) {
        strongConnect(node);
      }
    }

    return sccs;
  }

  /// Get all successor nodes (children) in the forest
  Set<ForestNode> _getSuccessors(ForestNode node) {
    var successors = <ForestNode>{};

    if (node is SymbolicNode) {
      for (var family in node.families) {
        successors.addAll(family.children);
      }
    } else if (node is IntermediateNode) {
      for (var family in node.families) {
        successors.addAll(family.children);
      }
    }

    return successors;
  }

  /// Collect all nodes reachable from the root
  void _collectAllNodes(ForestNode node, Set<ForestNode> collected) {
    if (collected.contains(node)) {
      return;
    }
    collected.add(node);

    if (node is SymbolicNode) {
      for (var family in node.families) {
        for (var child in family.children) {
          _collectAllNodes(child, collected);
        }
      }
    } else if (node is IntermediateNode) {
      for (var family in node.families) {
        for (var child in family.children) {
          _collectAllNodes(child, collected);
        }
      }
    }
  }

  /// Dynamic programming to count derivations with cycle detection
  BigInt _countDerivationsDP(
    ForestNode node,
    Map<ForestNode, BigInt> memo,
    Set<ForestNode> inProgress,
    Map<ForestNode, int> sccMap,
  ) {
    assert(
      sccMap.containsKey(node),
      "Invariant violation in _countDerivationsDP: SCC map must include every visited node.",
    );
    if (memo.containsKey(node)) {
      return memo[node]!;
    }

    // Detect cycle: if node is in progress, we have a cycle
    if (inProgress.contains(node)) {
      // In a well-formed parse forest, this shouldn't happen with bounded input
      // But if it does, return 1 to avoid infinite loops (actual count is undefined)
      return BigInt.one;
    }

    inProgress.add(node);

    BigInt count = BigInt.zero;

    if (node is SymbolicNode) {
      if (node.families.isEmpty) {
        count = BigInt.one; // Base case: leaf node
      } else {
        for (var family in node.families) {
          // Count = product of child counts
          BigInt familyCount = BigInt.one;
          for (var child in family.children) {
            var childCount = _countDerivationsDP(child, memo, inProgress, sccMap);
            familyCount *= childCount;
          }
          count += familyCount;
        }
      }
    } else if (node is IntermediateNode) {
      if (node.families.isEmpty) {
        count = BigInt.one;
      } else {
        for (var family in node.families) {
          BigInt familyCount = BigInt.one;
          for (var child in family.children) {
            var childCount = _countDerivationsDP(child, memo, inProgress, sccMap);
            familyCount *= childCount;
          }
          count += familyCount;
        }
      }
    } else {
      // Terminal, epsilon, or marker: count as 1
      count = BigInt.one;
    }

    inProgress.remove(node);
    memo[node] = count;
    return count;
  }

  /// Lazily yields all parse trees contained in the forest.
  Iterable<ParseTree> extract() sync* {
    GlushProfiler.increment("forest.extract.calls");
    var watch = GlushProfiler.enabled ? (Stopwatch()..start()) : null;
    try {
      yield* _extractTrees(root, {});
    } finally {
      watch?.stop();
      if (watch != null) {
        GlushProfiler.addMicros("forest.extract", watch.elapsedMicroseconds);
      }
    }
  }

  Iterable<ParseTree> _extractTrees(ForestNode node, Set<ForestNode> ancestors) sync* {
    if (ancestors.contains(node)) {
      return;
    }

    var childAncestors = {...ancestors, node};

    if (node is SymbolicNode) {
      if (node.families.isEmpty) {
        yield ParseTree(node, const []);
        return;
      }
      for (var family in node.families) {
        if (family.children.isEmpty) {
          yield ParseTree(node, const []);
        } else {
          yield* _extractFamilyTrees(node, family, childAncestors);
        }
      }
    } else if (node is IntermediateNode) {
      if (node.families.isEmpty) {
        yield ParseTree(node, const []);
        return;
      }
      for (var family in node.families) {
        if (family.children.isEmpty) {
          yield ParseTree(node, const []);
        } else {
          yield* _extractFamilyTrees(node, family, childAncestors);
        }
      }
    } else {
      yield ParseTree(node, const []);
    }
  }

  /// Lazily yields one [ParseTree] per combination of child subtrees for [family].
  Iterable<ParseTree> _extractFamilyTrees(
    ForestNode parent,
    Family family,
    Set<ForestNode> ancestors,
  ) sync* {
    switch (family) {
      case _EpsilonFamily():
        yield ParseTree(parent, const []);

      case _UnaryFamily(:var child):
        for (var tree in _extractTrees(child, ancestors)) {
          yield ParseTree(parent, [tree]);
        }
      case _BinaryFamily(:var left, :var right):
        for (var l in _extractTrees(left, ancestors)) {
          for (var r in _extractTrees(right, ancestors)) {
            yield ParseTree(parent, [l, r]);
          }
        }
    }
  }

  @override
  String toString() {
    return "ParseForest(root=$root, nodes=${countNodes()}, families=${countFamilies()})";
  }
}

/// A single parse tree extracted from the forest
class ParseTree {
  ParseTree(this.node, this.children);
  final ForestNode node;
  final List<ParseTree> children;

  /// Convert to a readable string representation
  String toTreeString([int indent = 0]) {
    var prefix = "  " * indent;
    var str = "$prefix$node\n";
    return str + children.map((c) => c.toTreeString(indent + 1)).join();
  }

  String toPrecedenceString(String input) {
    if (children.isEmpty) {
      return input.substring(node.start, node.end);
    }

    List<String> mapped = children
        .where((c) => c.node.start != c.node.end)
        .map((c) => c.toPrecedenceString(input))
        .toList();

    if (mapped.length == 1) {
      return mapped.single;
    }

    return "(${mapped.join()})";
  }

  @override
  String toString() => node.toString();
}
