/// Shared Packed Parse Forest (SPPF) implementation
library glush.sppf;

import 'mark.dart';
import 'patterns.dart';

/// Base class for all forest nodes
sealed class ForestNode {
  final PatternSymbol symbol;
  final int start;
  final int end;

  ForestNode(this.start, this.end, this.symbol);

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
  final int token;

  TerminalNode(super.start, super.end, super.pattern, this.token);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is TerminalNode && token == (other).token;

  @override
  int get hashCode => super.hashCode ^ token.hashCode;

  @override
  String toString() => 'Terminal($token, [$start, $end))';
}

/// Marker node (for named positions / @mark identifiers)
class MarkerNode extends ForestNode {
  final String name;

  MarkerNode(int position, PatternSymbol symbol, this.name) : super(position, position, symbol);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is MarkerNode && name == (other).name;

  @override
  int get hashCode => super.hashCode ^ name.hashCode;

  @override
  String toString() => 'Marker(\$name)[$start]';
}

/// Symbolic node (non-terminal)
class SymbolicNode extends ForestNode {
  final Set<Family> families;

  SymbolicNode(super.start, super.end, super.symbol) : families = {};

  void addFamily(Family family) {
    if (!families.contains(family)) {
      families.add(family);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is SymbolicNode && symbol == other.symbol;

  @override
  int get hashCode => super.hashCode ^ symbol.hashCode;

  @override
  String toString() => '$symbol[$start:$end]';
}

/// Intermediate node (represents semantic actions on children)
class IntermediateNode extends ForestNode {
  final Set<Family> families;

  IntermediateNode(super.start, super.end, super.symbol) : families = {};

  void addFamily(Family family) {
    if (!families.contains(family)) {
      families.add(family);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      super == other &&
          other is IntermediateNode &&
          families.difference(other.families).isEmpty &&
          families.length == other.families.length;

  @override
  int get hashCode => super.hashCode;

  @override
  String toString() => 'Intermediate($symbol, [$start, $end))';
}

/// Family of parse derivations (alternatives)
sealed class Family {
  final List<Mark> marks;
  const Family([this.marks = const []]);
  const factory Family.epsilon([List<Mark> marks]) = _EpsilonFamily;
  const factory Family.unary(ForestNode child, [List<Mark> marks]) = _UnaryFamily;
  const factory Family.binary(ForestNode left, ForestNode right, [List<Mark> marks]) =
      _BinaryFamily;

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
  final ForestNode child;
  const _UnaryFamily(this.child, [super.marks]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _UnaryFamily && child == other.child;

  @override
  int get hashCode => child.hashCode;
}

/// Binary Seq(left, right) — the normal case
class _BinaryFamily extends Family {
  final ForestNode left;
  final ForestNode right;
  const _BinaryFamily(this.left, this.right, [super.marks]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BinaryFamily && left == other.left && right == other.right;

  @override
  int get hashCode => left.hashCode ^ right.hashCode;
}

/// Epsilon node (empty parse)
class EpsilonNode extends ForestNode {
  EpsilonNode(int position, PatternSymbol symbol) : super(position, position, symbol);

  @override
  String toString() => 'ε[$start]';
}

/// Forest node manager (deduplicates and caches nodes)
class ForestNodeManager {
  final Map<String, ForestNode> _nodeCache = {};
  final Set<SymbolicNode> _symbolicNodes = {};
  final Set<TerminalNode> _terminalNodes = {};
  final Set<IntermediateNode> _intermediateNodes = {};
  final Set<MarkerNode> _markerNodes = {};

  String _makeCacheKey(String type, int start, int end, PatternSymbol symbol) {
    return '$type:$start:$end:$symbol';
  }

  /// Get or create a terminal node
  TerminalNode terminal(int start, int end, PatternSymbol symbol, int token) {
    final key = _makeCacheKey('term', start, end, symbol);
    if (_nodeCache[key] case TerminalNode node) {
      return node;
    }
    final node = TerminalNode(start, end, symbol, token);
    _nodeCache[key] = node;
    _terminalNodes.add(node);
    return node;
  }

  /// Get or create a symbolic node
  SymbolicNode symbolic(int start, int end, PatternSymbol symbol) {
    final key = _makeCacheKey('sym', start, end, symbol);
    if (_nodeCache[key] case SymbolicNode node) {
      return node;
    }
    final node = SymbolicNode(start, end, symbol);
    _nodeCache[key] = node;
    _symbolicNodes.add(node);
    return node;
  }

  /// Get or create an intermediate node
  IntermediateNode intermediate(int start, int end, PatternSymbol symbol) {
    final key = _makeCacheKey('inter', start, end, symbol);
    if (_nodeCache[key] case IntermediateNode node) {
      return node;
    }
    final node = IntermediateNode(start, end, symbol);
    _nodeCache[key] = node;
    _intermediateNodes.add(node);
    return node;
  }

  /// Get or create an epsilon node
  EpsilonNode epsilon(int position, PatternSymbol symbol) {
    final key = _makeCacheKey('eps', position, position, symbol);
    if (_nodeCache[key] case EpsilonNode node) {
      return node;
    }
    final node = EpsilonNode(position, symbol);
    _nodeCache[key] = node;
    return node;
  }

  /// Get or create a marker node
  MarkerNode marker(int position, Marker marker) {
    final key = _makeCacheKey('mark', position, position, marker.symbolId!);
    if (_nodeCache[key] case MarkerNode node) {
      return node;
    }
    final node = MarkerNode(position, marker.symbolId!, marker.name);
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
  final ForestNodeManager nodeManager;
  final SymbolicNode root;
  final List<Mark> marks;

  ParseForest(this.nodeManager, this.root, this.marks);

  /// Count total nodes in the forest
  int countNodes() {
    final visited = <ForestNode>{};
    _countNodesRecursive(root, visited);
    return visited.length;
  }

  void _countNodesRecursive(ForestNode node, Set<ForestNode> visited) {
    if (visited.contains(node)) return;
    visited.add(node);

    if (node is SymbolicNode) {
      for (final family in node.families) {
        for (final child in family.children) {
          _countNodesRecursive(child, visited);
        }
      }
    } else if (node is IntermediateNode) {
      for (final family in node.families) {
        for (final child in family.children) {
          _countNodesRecursive(child, visited);
        }
      }
    }
  }

  /// Count total families (derivations) in the forest
  int countFamilies() {
    final visited = <ForestNode>{};
    return _countFamiliesRecursive(root, visited);
  }

  int _countFamiliesRecursive(ForestNode node, Set<ForestNode> visited) {
    if (visited.contains(node)) return 0;
    visited.add(node);

    int count = 0;
    if (node case SymbolicNode(:var families) || IntermediateNode(:var families)) {
      count = families.length;
      for (final family in families) {
        for (final child in family.children) {
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
  Map<String, Object?> countDerivationsWithSCC() {
    final sccs = _findSCCs();
    final sccMap = <ForestNode, int>{};

    // Map each node to its SCC id
    for (int i = 0; i < sccs.length; i++) {
      for (final node in sccs[i]) {
        sccMap[node] = i;
      }
    }

    // Check for cycles: if any SCC has more than one node, or if a node reaches itself
    bool hasCycles = sccs.any((scc) => scc.length > 1);

    // Count derivations using memoization
    final memo = <ForestNode, BigInt>{};
    final inProgress = <ForestNode>{};

    final count = _countDerivationsDP(root, memo, inProgress, sccMap);

    return {
      'count': count,
      'hasCycles': hasCycles,
      'sccs': sccs.length,
      'forestSize': countNodes(),
    };
  }

  /// Find strongly connected components using Tarjan's algorithm
  List<Set<ForestNode>> _findSCCs() {
    int index = 0;
    final stack = <ForestNode>[];
    final indices = <ForestNode, int>{};
    final lowlinks = <ForestNode, int>{};
    final onStack = <ForestNode, bool>{};
    final sccs = <Set<ForestNode>>[];

    void strongConnect(ForestNode node) {
      indices[node] = index;
      lowlinks[node] = index;
      index++;
      stack.add(node);
      onStack[node] = true;

      // Collect all successors (children) of this node
      final successors = _getSuccessors(node);

      for (final successor in successors) {
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
        final scc = <ForestNode>{};
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
    final allNodes = <ForestNode>{};
    _collectAllNodes(root, allNodes);

    for (final node in allNodes) {
      if (!indices.containsKey(node)) {
        strongConnect(node);
      }
    }

    return sccs;
  }

  /// Get all successor nodes (children) in the forest
  Set<ForestNode> _getSuccessors(ForestNode node) {
    final successors = <ForestNode>{};

    if (node is SymbolicNode) {
      for (final family in node.families) {
        successors.addAll(family.children);
      }
    } else if (node is IntermediateNode) {
      for (final family in node.families) {
        successors.addAll(family.children);
      }
    }

    return successors;
  }

  /// Collect all nodes reachable from the root
  void _collectAllNodes(ForestNode node, Set<ForestNode> collected) {
    if (collected.contains(node)) return;
    collected.add(node);

    if (node is SymbolicNode) {
      for (final family in node.families) {
        for (final child in family.children) {
          _collectAllNodes(child, collected);
        }
      }
    } else if (node is IntermediateNode) {
      for (final family in node.families) {
        for (final child in family.children) {
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
        for (final family in node.families) {
          // Count = product of child counts
          BigInt familyCount = BigInt.one;
          for (final child in family.children) {
            final childCount = _countDerivationsDP(child, memo, inProgress, sccMap);
            familyCount *= childCount;
          }
          count += familyCount;
        }
      }
    } else if (node is IntermediateNode) {
      if (node.families.isEmpty) {
        count = BigInt.one;
      } else {
        for (final family in node.families) {
          BigInt familyCount = BigInt.one;
          for (final child in family.children) {
            final childCount = _countDerivationsDP(child, memo, inProgress, sccMap);
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
    yield* _extractTrees(root);
  }

  Iterable<ParseTree> _extractTrees(ForestNode node) sync* {
    if (node is SymbolicNode) {
      if (node.families.isEmpty) {
        yield ParseTree(node, const []);
        return;
      }
      for (final family in node.families) {
        if (family.children.isEmpty) {
          yield ParseTree(node, const []);
        } else {
          yield* _extractFamilyTrees(node, family);
        }
      }
    } else if (node is IntermediateNode) {
      if (node.families.isEmpty) {
        yield ParseTree(node, const []);
        return;
      }
      for (final family in node.families) {
        if (family.children.isEmpty) {
          yield ParseTree(node, const []);
        } else {
          yield* _extractFamilyTrees(node, family);
        }
      }
    } else {
      yield ParseTree(node, const []);
    }
  }

  /// Lazily yields one [ParseTree] per combination of child subtrees for [family].
  Iterable<ParseTree> _extractFamilyTrees(ForestNode parent, Family family) sync* {
    switch (family) {
      case _EpsilonFamily():
        break;
      case _UnaryFamily(:final child):
        for (final tree in _extractTrees(child)) {
          yield ParseTree(parent, [tree]);
        }
      case _BinaryFamily(:final left, :final right):
        for (final l in _extractTrees(left)) {
          for (final r in _extractTrees(right)) {
            yield ParseTree(parent, [l, r]);
          }
        }
    }
  }

  @override
  String toString() {
    return 'ParseForest(root=$root, nodes=${countNodes()}, families=${countFamilies()})';
  }
}

/// A single parse tree extracted from the forest
class ParseTree {
  final ForestNode node;
  final List<ParseTree> children;

  ParseTree(this.node, this.children);

  /// Convert to a readable string representation
  String toTreeString([int indent = 0]) {
    final prefix = '  ' * indent;
    final str = '$prefix$node\n';
    return str + children.map((c) => c.toTreeString(indent + 1)).join('');
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

    return "(${mapped.join("")})";
  }

  @override
  String toString() => node.toString();
}
