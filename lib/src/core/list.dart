/// Custom list implementation for managing parse alternatives
library glush.list;

import "package:glush/src/helper/diagonal.dart";
import "package:meta/meta.dart";

/// Abstract base class for managing parse alternatives as a tree structure.
@immutable
sealed class GlushList<T> {
  const GlushList();

  const factory GlushList.empty() = EmptyList<T>._;

  factory GlushList.branched(GlushList<T> left, GlushList<T> right) {
    if (left.isEmpty) {
      return right;
    }
    if (right.isEmpty) {
      return left;
    }
    if (identical(left, right)) {
      return left;
    }
    return BranchedList<T>._(left, right);
  }

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

      switch (item) {
        case EmptyList():
          continue;
        case Push(:var parent, :var data):
          stack.add(data);
          stack.add(_dataMarker);
          stack.add(parent);
        case Concat(:var left, :var right):
          stack.add(right);
          stack.add(left);
        case BranchedList(:var left, :var right):
          if (right != null) {
            stack.add(right);
          }
          stack.add(left);
      }
    }
  }

  T? get lastOrNull {
    var node = this;
    while (node is Push<T>) {
      return node.data;
    }
    if (node is Concat<T>) {
      return node.right.lastOrNull;
    }
    return null;
  }

  bool get isEmpty;
  int countDerivations();
  GlushList<T> evaluate() => this;
}

class EmptyList<T> extends GlushList<T> {
  const EmptyList._();
  @override
  bool get isEmpty => true;
  @override
  int countDerivations() => 1;
}

class Push<T> extends GlushList<T> {
  const Push._(this.parent, this.data);
  final GlushList<T> parent;
  final T data;
  @override
  bool get isEmpty => false;
  @override
  int countDerivations() => parent.countDerivations();
}

class Concat<T> extends GlushList<T> {
  const Concat._(this.left, this.right);
  final GlushList<T> left;
  final GlushList<T> right;
  @override
  bool get isEmpty => false;
  @override
  int countDerivations() => left.countDerivations() * right.countDerivations();
}

class BranchedList<T> extends GlushList<T> {
  const BranchedList._(this.left, [this.right]);
  final GlushList<T> left;
  final GlushList<T>? right;
  @override
  bool get isEmpty => false;
  @override
  int countDerivations() => left.countDerivations() + (right?.countDerivations() ?? 0);
}

/// A lazy version of [GlushList] that defers structural operations.
sealed class LazyGlushList<T> {
  const LazyGlushList();

  const factory LazyGlushList.empty() = LazyEmpty<T>._;

  GlushList<T> evaluate();
  bool get isEmpty;

  LazyGlushList<T> add(LazyVal<T> val) => LazyPush<T>._(this, val);

  LazyGlushList<T> addList(LazyGlushList<T> other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return LazyConcat<T>._(this, other);
  }

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
      case LazyEvaluated<Object?>():
        res = node.list.countDerivations();
      case LazyReturn<Object?>():
        res = _count(node.provider(), memo);
    }
    return memo[node] = res;
  }
}

sealed class _LazyBase<T> extends LazyGlushList<T> {
  _LazyBase();
  @override
  GlushList<T> evaluate() {
    if (_evaluated != null) {
      return _evaluated!;
    }
    return _evaluated = _evaluate();
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

class LazyReturn<T> extends _LazyBase<T> {
  LazyReturn(this.provider);
  final LazyGlushList<T> Function() provider;
  @override
  GlushList<T> _evaluate() => provider().evaluate();
  @override
  bool get isEmpty => false;
}

abstract class LazyVal<T> {
  const LazyVal();
  T evaluate();
}

class ConstantLazyVal<T> extends LazyVal<T> {
  const ConstantLazyVal(this.value);
  final T value;
  @override
  T evaluate() => value;
}

class ClosureVal<T> extends LazyVal<T> {
  const ClosureVal(this.thunk);
  final T Function() thunk;
  @override
  T evaluate() => thunk();
}

class LazyEvaluated<T> extends LazyGlushList<T> {
  const LazyEvaluated(this.list);
  final GlushList<T> list;
  @override
  GlushList<T> evaluate() => list;
  @override
  bool get isEmpty => list.isEmpty;
}

extension GlushListVisualizer<T> on GlushList<T> {
  Iterable<List<T>> allMarkPaths() => _collect(this, {});

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
        for (var pPath in _collect(node.parent, visiting)) {
          yield [...pPath, node.data];
        }
      case Concat<T>():
        for (var (l, r) in diagonalize(
          _collect(node.left, visiting),
          _collect(node.right, visiting),
        )) {
          yield [...l, ...r];
        }
    }
  }
}

extension LazyGlushListVisualizer<T> on LazyGlushList<T> {
  Iterable<List<T>> allMarkPaths() => _collectLazy(this, {});

  Iterable<List<T>> _collectLazy(LazyGlushList<T> node, Set<int> stack) {
    if (stack.contains(node.hashCode)) {
      return const [];
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
    } else if (node is LazyEvaluated<T>) {
      results.addAll(node.list.allMarkPaths());
    } else if (node is LazyReturn<T>) {
      results.addAll(_collectLazy(node.provider(), newStack));
    }

    return results;
  }
}
