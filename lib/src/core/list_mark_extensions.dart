/// GlushList extensions for Mark-specific operations.
///
/// This library provides Mark-specific operations on GlushList and LazyGlushList,
/// keeping the core list.dart library free from glush-specific dependencies.
library glush.list_mark_extensions;

import "dart:collection";

import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/helper/diagonal.dart";

/// Extension methods for List<Mark> to extract and format marks.
extension ListMarkExtractor on List<Mark> {
  /// Converts the mark list to a list of strings, merging consecutive StringMarks.
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

  /// Extracts the string values from marks.
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

/// Extension methods for GlushList<Mark> to handle conjunctions.
extension GlushListMarkExtensions on GlushList<Mark> {
  /// Collects all paths through the GlushList, creating ConjunctionMarks for parallel branches.
  /// Mark-specific version that properly handles conjunctions with ConjunctionMark.
  Iterable<List<Mark>> allMarkPaths() {
    return _collectMarkPaths(this, {});
  }

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

/// Extension methods for LazyGlushList<Mark> to handle lazy conjunctions.
extension LazyGlushListMarkExtensions on LazyGlushList<Mark> {
  /// Collects all paths through the LazyGlushList, creating ConjunctionMarks for parallel branches.
  /// Mark-specific version that properly handles conjunctions with ConjunctionMark.
  Iterable<List<Mark>> allMarkPaths() {
    return _collectLazyMarkPaths(this, HashSet());
  }

  Iterable<List<Mark>> _collectLazyMarkPaths(LazyGlushList<Mark> node, Set<int> stack) sync* {
    if (stack.contains(node.hashCode)) {
      return;
    }

    var newStack = {...stack, node.hashCode};
    if (node is LazyEmpty<Mark>) {
      yield const [];
    } else if (node is LazyPush<Mark>) {
      for (var pPath in _collectLazyMarkPaths(node.parent, newStack)) {
        yield [...pPath, node.val.evaluate()];
      }
    } else if (node is LazyBranched<Mark>) {
      yield* _collectLazyMarkPaths(node.left, newStack);
      yield* _collectLazyMarkPaths(node.right, newStack);
    } else if (node is LazyConcat<Mark>) {
      for (var (l, r) in diagonalize(
        _collectLazyMarkPaths(node.left, newStack),
        _collectLazyMarkPaths(node.right, newStack),
      )) {
        yield [...l, ...r];
      }
    } else if (node is LazyConjunction<Mark>) {
      // For Mark conjunctions, expand all combinations into separate paths.
      // Don't wrap in ConjunctionMark - let the combinations expand naturally.
      for (var (leftPath, rightPath) in diagonalize(
        _collectLazyMarkPaths(node.left, newStack),
        _collectLazyMarkPaths(node.right, newStack),
      )) {
        var leftList = LazyGlushList.fromList(leftPath);
        var rightList = LazyGlushList.fromList(rightPath);
        yield [ConjunctionMark(leftList, rightList, 0)];
      }
    } else if (node is LazyEvaluated<Mark>) {
      yield* node.list.allMarkPaths();
    } else if (node is LazyReturn<Mark>) {
      yield* _collectLazyMarkPaths(node.provider(), newStack);
    }
  }
}
