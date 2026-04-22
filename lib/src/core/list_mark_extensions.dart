/// GlushList extensions for Mark-specific operations.
///
/// This library provides Mark-specific operations on GlushList and LazyGlushList,
/// keeping the core list.dart library free from glush-specific dependencies.
library glush.list_mark_extensions;

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/helper/diagonal.dart";

/// Extension methods for [List<Mark>] to extract and format marks.
///
/// These utilities provide a way to convert the abstract [Mark] forest results
/// into more human-readable or machine-processable formats, such as merged
/// string lists or raw mark identifiers.
extension ListMarkExtractor on List<Mark> {
  /// Converts the mark list to a list of strings, merging consecutive [StringMark]s.
  ///
  /// This is particularly useful for final result presentation where multiple
  /// adjacent character-level marks should be treated as a single cohesive
  /// token string. It also preserves [NamedMark]s and [LabelStartMark]s as
  /// individual entries in the resulting list.
  List<String> toStringList() {
    var result = <String>[];
    String? currentStringMark;
    for (var mark in this) {
      if (mark is LabelStartMark) {
        if (currentStringMark != null) {
          result.add(currentStringMark);
          currentStringMark = null;
        }
        result.add(mark.name);
      }
    }
    if (currentStringMark != null) {
      result.add(currentStringMark);
    }
    return result;
  }
}

/// Extension methods for [GlushList<Mark>] to handle mark-specific forest operations.
extension GlushListMarkExtensions on GlushList<Mark> {
  /// Collects all flattened mark paths through the [GlushList].
  ///
  /// This specialized version of path collection ensures that conjunctions
  /// are handled correctly by expanding all parallel combinations into distinct
  /// paths. This allows callers to see every possible semantic interpretation
  /// of a given input span.
  Iterable<List<Mark>> allMarkPaths() {
    return _collectMarkPaths(this, {});
  }

  /// Internal recursive collector for mark paths with cycle prevention.
  Iterable<List<Mark>> _collectMarkPaths(
    GlushList<Mark> node,
    Set<GlushList<Mark>> visiting,
  ) sync* {
    switch (node) {
      case EmptyList<Mark>():
        yield const [];
      case BranchedList<Mark>():
        yield* _collectMarkPaths(node.left, visiting);
        if (node.right != null) {
          yield* _collectMarkPaths(node.right!, visiting);
        }
      case Push<Mark>():
        var data = node.data;
        for (var pPath in _collectMarkPaths(node.parent, visiting)) {
          yield [...pPath, data];
        }
      case Concat<Mark>():
        for (var (l, r) in diagonalize(
          _collectMarkPaths(node.left, visiting),
          _collectMarkPaths(node.right, visiting),
        )) {
          yield [...l, ...r];
        }
      case Conjunction<Mark>():
        // For Mark conjunctions, expand all combinations into separate paths.
        // Don't wrap in ConjunctionMark - let the combinations expand naturally.
        for (var (l, r) in diagonalize(
          _collectMarkPaths(node.left, visiting),
          _collectMarkPaths(node.right, visiting),
        )) {
          yield [...l, ...r];
        }
    }
  }
}

/// Extension methods for [LazyGlushList<Mark>] to handle lazy mark-specific operations.
extension LazyGlushListMarkExtensions on LazyGlushList<Mark> {
  /// Collects all flattened mark paths through the [LazyGlushList].
  ///
  /// This method triggers the evaluation of lazy values and expands all
  /// possible derivations. It is particularly important for conjunctions,
  /// where it explicitly wraps parallel results in [ConjunctionMark] nodes
  /// to preserve the structural information of the match.
  Iterable<List<Mark>> allMarkPaths() {
    return _collectLazyMarkPaths(this, const {});
  }

  /// Internal recursive collector for lazy mark paths with visit tracking.
  ///
  /// Visit counts are used to handle recursive structures (cycles) in the
  /// grammar. When a cycle is detected, the collector yields an empty path
  /// to allow termination at that depth while still exploring other branches.
  Iterable<List<Mark>> _collectLazyMarkPaths(
    LazyGlushList<Mark> node,
    Map<int, int> visitCounts, // Track how many times each node has been visited IN THIS EXECUTION
  ) sync* {
    var nodeId = node.hashCode;
    var currentCount = visitCounts[nodeId] ?? 0;

    // Track this visit
    var newVisitCounts = {...visitCounts, nodeId: currentCount + 1};

    if (node is LazyEmpty<Mark>) {
      yield const [];
    } else if (node is LazyPush<Mark>) {
      for (var pPath in _collectLazyMarkPaths(node.parent, newVisitCounts)) {
        yield [...pPath, node.val.evaluate()];
      }
    } else if (node is LazyBranched<Mark>) {
      yield* _collectLazyMarkPaths(node.left, newVisitCounts);
      yield* _collectLazyMarkPaths(node.right, newVisitCounts);
    } else if (node is LazyConcat<Mark>) {
      for (var (l, r) in diagonalize(
        _collectLazyMarkPaths(node.left, newVisitCounts),
        _collectLazyMarkPaths(node.right, newVisitCounts),
      )) {
        yield [...l, ...r];
      }
    } else if (node is LazyConjunction<Mark>) {
      // For Mark conjunctions, expand all combinations into separate paths.
      // Don't wrap in ConjunctionMark - let the combinations expand naturally.
      for (var (leftPath, rightPath) in diagonalize(
        _collectLazyMarkPaths(node.left, newVisitCounts),
        _collectLazyMarkPaths(node.right, newVisitCounts),
      )) {
        var leftList = LazyGlushList.fromList(leftPath);
        var rightList = LazyGlushList.fromList(rightPath);
        yield [ConjunctionMark(leftList, rightList, 0)];
      }
    } else if (node is LazyEvaluated<Mark>) {
      yield* node.list.allMarkPaths();
    } else if (node is LazyReturn<Mark>) {
      // If we've encountered this node before in this path, yield a terminal result
      // at this depth level, then continue infinitely deeper
      if (currentCount > 0) {
        // Yield empty to create a path at this recursion depth
        yield const [];
      }

      // Continue recursing infinitely (no depth limit)
      for (var path in _collectLazyMarkPaths(node.provider(), newVisitCounts)) {
        yield path;
      }
    }
  }
}
