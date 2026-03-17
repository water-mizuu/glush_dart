/// Shared Packed Parse Forest (SPPF) implementation
library glush.sppf;

import 'mark.dart';
import 'patterns.dart';

/// Base class for all forest nodes
sealed class ForestNode {
  final Pattern pattern;
  final int start;
  final int end;

  ForestNode(this.start, this.end, this.pattern);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForestNode &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          pattern == other.pattern;

  @override
  int get hashCode => start.hashCode ^ end.hashCode ^ pattern.hashCode;
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

  MarkerNode(int position, Pattern pattern, this.name) : super(position, position, pattern);

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

  SymbolicNode(super.start, super.end, super.pattern, this.symbol);

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

  IntermediateNode(super.start, super.end, super.pattern, this.description);

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
  EpsilonNode(int position, Pattern pattern) : super(position, position, pattern);

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

  String _makeCacheKey(String type, int start, int end, Pattern pattern, [String detail = '']) {
    return '$type:$start:$end:${identityHashCode(pattern)}:$detail';
  }

  /// Get or create a terminal node
  TerminalNode terminal(int start, int end, Pattern pattern, int token) {
    final key = _makeCacheKey('term', start, end, pattern, token.toString());
    if (_nodeCache[key] case TerminalNode node) {
      return node;
    }
    final node = TerminalNode(start, end, pattern, token);
    _nodeCache[key] = node;
    _terminalNodes.add(node);
    return node;
  }

  /// Get or create a symbolic node
  SymbolicNode symbolic(int start, int end, Pattern rule) {
    final key = _makeCacheKey('sym', start, end, rule, rule.symbolId!);
    if (_nodeCache[key] case SymbolicNode node) {
      return node;
    }
    final node = SymbolicNode(start, end, rule, rule.symbolId!);
    _nodeCache[key] = node;
    _symbolicNodes.add(node);
    return node;
  }

  /// Get or create an intermediate node
  IntermediateNode intermediate(int start, int end, Pattern pattern, String description) {
    final key = _makeCacheKey('inter', start, end, pattern, description);
    if (_nodeCache[key] case IntermediateNode node) {
      return node;
    }
    final node = IntermediateNode(start, end, pattern, description);
    _nodeCache[key] = node;
    _intermediateNodes.add(node);
    return node;
  }

  /// Get or create an epsilon node
  EpsilonNode epsilon(int position, Pattern pattern) {
    final key = _makeCacheKey('eps', position, position, pattern);
    if (_nodeCache[key] case EpsilonNode node) {
      return node;
    }
    final node = EpsilonNode(position, pattern);
    _nodeCache[key] = node;
    return node;
  }

  /// Get or create a marker node
  MarkerNode marker(int position, Marker pattern) {
    final key = _makeCacheKey('mark', position, position, pattern, pattern.name);
    if (_nodeCache[key] case MarkerNode node) {
      return node;
    }
    final node = MarkerNode(position, pattern, pattern.name);
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
    // Collect sub-iterables for each child position
    final childOptions = family.children.map((child) => _extractTrees(child).toList()).toList();
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

  String toPrecedenceString(String input) {
    final mapped = children.map((c) => c.toPrecedenceString(input)).join("");
    if (mapped.isEmpty) {
      return input.substring(node.start, node.end);
    }

    return switch (children.length) { > 1 => "($mapped)", 1 => mapped, _ => throw Error() };
  }

  @override
  String toString() => node.toString();
}
