/// Shared Packed Parse Forest (SPPF) implementation
library glush.sppf;

import 'mark.dart';

/// Base class for all forest nodes
abstract class ForestNode {
  final int start;
  final int end;

  ForestNode(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForestNode &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => start.hashCode ^ end.hashCode;
}

/// Terminal node (matches a token)
class TerminalNode extends ForestNode {
  final int token;

  TerminalNode(super.start, super.end, this.token);

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

  MarkerNode(int position, this.name) : super(position, position);

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
  final String symbol;
  final List<Family> families = [];

  SymbolicNode(super.start, super.end, this.symbol);

  void addFamily(Family family) {
    if (!families.contains(family)) {
      families.add(family);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || super == other && other is SymbolicNode && symbol == (other).symbol;

  @override
  int get hashCode => super.hashCode ^ symbol.hashCode;

  @override
  String toString() => '$symbol[$start:$end]';
}

/// Intermediate node (represents semantic actions on children)
class IntermediateNode extends ForestNode {
  final String description;
  final List<Family> families = [];

  IntermediateNode(super.start, super.end, this.description);

  void addFamily(Family family) {
    if (!families.contains(family)) {
      families.add(family);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      super == other && other is IntermediateNode && description == (other).description;

  @override
  int get hashCode => super.hashCode ^ description.hashCode;

  @override
  String toString() => 'Intermediate($description, [$start, $end))';
}

/// Family of parse derivations (alternatives)
class Family {
  final List<ForestNode> children;
  final List<Mark> marks;

  Family(this.children, [this.marks = const []]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Family &&
          runtimeType == other.runtimeType &&
          _listEquals(children, (other).children) &&
          _listEquals(marks, (other).marks);

  @override
  int get hashCode =>
      children.fold(0, (h, c) => h ^ c.hashCode) ^ marks.fold(0, (h, m) => h ^ m.hashCode);

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() {
    final childStr = children.join(', ');
    return 'Family([$childStr])';
  }
}

/// Epsilon node (empty parse)
class EpsilonNode extends ForestNode {
  EpsilonNode(int position) : super(position, position);

  @override
  String toString() => 'ε[$start]';
}

/// Forest node manager (deduplicates and caches nodes)
class ForestNodeManager {
  final Map<String, ForestNode> _nodeCache = {};
  final List<SymbolicNode> _symbolicNodes = [];
  final List<TerminalNode> _terminalNodes = [];
  final List<IntermediateNode> _intermediateNodes = [];
  final List<MarkerNode> _markerNodes = [];

  String _makeCacheKey(String type, int start, int end, [String detail = '']) {
    return '$type:$start:$end:$detail';
  }

  /// Get or create a terminal node
  TerminalNode terminal(int start, int end, int token) {
    final key = _makeCacheKey('term', start, end, token.toString());
    if (_nodeCache[key] case TerminalNode node) {
      return node;
    }
    final node = TerminalNode(start, end, token);
    _nodeCache[key] = node;
    _terminalNodes.add(node);
    return node;
  }

  /// Get or create a symbolic node
  SymbolicNode symbolic(int start, int end, String symbol) {
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
  IntermediateNode intermediate(int start, int end, String description) {
    final key = _makeCacheKey('inter', start, end, description);
    if (_nodeCache[key] case IntermediateNode node) {
      return node;
    }
    final node = IntermediateNode(start, end, description);
    _nodeCache[key] = node;
    _intermediateNodes.add(node);
    return node;
  }

  /// Get or create an epsilon node
  EpsilonNode epsilon(int position) {
    final key = _makeCacheKey('eps', position, position);
    if (_nodeCache[key] case EpsilonNode node) {
      return node;
    }
    final node = EpsilonNode(position);
    _nodeCache[key] = node;
    return node;
  }

  /// Get or create a marker node
  MarkerNode marker(int position, String name) {
    final key = _makeCacheKey('mark', position, position, name);
    if (_nodeCache[key] case MarkerNode node) {
      return node;
    }
    final node = MarkerNode(position, name);
    _nodeCache[key] = node;
    _markerNodes.add(node);
    return node;
  }

  List<SymbolicNode> get symbolicNodes => _symbolicNodes;
  List<TerminalNode> get terminalNodes => _terminalNodes;
  List<IntermediateNode> get intermediateNodes => _intermediateNodes;
  List<MarkerNode> get markerNodes => _markerNodes;
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
    if (node is SymbolicNode) {
      count = node.families.length;
      for (final family in node.families) {
        for (final child in family.children) {
          count += _countFamiliesRecursive(child, visited);
        }
      }
    } else if (node is IntermediateNode) {
      count = node.families.length;
      for (final family in node.families) {
        for (final child in family.children) {
          count += _countFamiliesRecursive(child, visited);
        }
      }
    }
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
    } else if (node is TerminalNode || node is EpsilonNode || node is MarkerNode) {
      yield ParseTree(node, const []);
    }
  }

  /// Lazily yields one [ParseTree] per combination of child subtrees for [family].
  Iterable<ParseTree> _extractFamilyTrees(SymbolicNode parent, Family family) sync* {
    // Collect sub-iterables for each child position
    final childOptions = family.children
        .map((child) => _extractTrees(child).toList())
        .toList();
    // Yield the Cartesian product of the child options as ParseTree nodes
    for (final combination in _cartesianProduct(childOptions)) {
      yield ParseTree(parent, combination);
    }
  }

  /// Lazily yields every combination (one item from each of [lists] in order).
  Iterable<List<ParseTree>> _cartesianProduct(List<List<ParseTree>> lists) sync* {
    if (lists.isEmpty) {
      yield const [];
      return;
    }
    for (final head in lists.first) {
      for (final tail in _cartesianProduct(lists.sublist(1))) {
        yield [head, ...tail];
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

  @override
  String toString() => node.toString();
}
