import "dart:math" show Random, max;

import "package:glush/src/core/mark.dart";
import "package:glush/src/parser/common/parse_state.dart";

final _random = Random();

/// A node in the IntervalTree (Treap-based, Persistent).
class IntervalNode<T extends Shiftable<T>> {
  IntervalNode(
    this.start,
    this.end,
    this.result, {
    this.maxEnd = -1,
    this.priority = -1,
    this.lazyShift = 0,
    this.left,
    this.right,
  });
  final int start;
  final int end;
  final int maxEnd;
  final T result;
  final int priority;
  final int lazyShift;

  final IntervalNode<T>? left;
  final IntervalNode<T>? right;

  IntervalNode<T> withShift(int delta) {
    if (delta == 0) {
      return this;
    }
    return IntervalNode<T>(
      start + delta,
      end + delta,
      result,
      maxEnd: maxEnd + delta,
      priority: priority,
      lazyShift: lazyShift + delta,
      left: left,
      right: right,
    );
  }

  IntervalNode<T> push() {
    if (lazyShift == 0) {
      return this;
    }
    var shiftedResult = result.shifted(lazyShift);
    return IntervalNode<T>(
      start,
      end,
      shiftedResult,
      maxEnd: maxEnd,
      priority: priority,
      left: left?.withShift(lazyShift),
      right: right?.withShift(lazyShift),
    );
  }

  IntervalNode<T> withChildren(IntervalNode<T>? newLeft, IntervalNode<T>? newRight) {
    var newMaxEnd = end;
    if (newLeft != null) {
      newMaxEnd = max(newMaxEnd, newLeft.maxEnd);
    }
    if (newRight != null) {
      newMaxEnd = max(newMaxEnd, newRight.maxEnd);
    }
    return IntervalNode<T>(
      start,
      end,
      result,
      maxEnd: newMaxEnd,
      priority: priority,
      lazyShift: lazyShift,
      left: newLeft,
      right: newRight,
    );
  }

  static IntervalNode<T> create<T extends Shiftable<T>>(int start, int end, T result) {
    return IntervalNode<T>(start, end, result, maxEnd: end, priority: _random.nextInt(1 << 31));
  }
}

/// An augmented Treap that stores intervals [start, end) and supports
/// O(log N) insertion, overlapping invalidation, and lazy position shifting.
/// This implementation is persistent (nodes are immutable).
class IntervalTree<T extends Shiftable<T>> {
  IntervalTree([this.root]);
  IntervalNode<T>? root;

  /// Inserts a new parse result interval.
  void insert(int start, int end, T result) {
    var newNode = IntervalNode.create<T>(start, end, result);
    root = _insertRec(root, newNode);
  }

  IntervalNode<T> _insertRec(IntervalNode<T>? node, IntervalNode<T> newNode) {
    if (node == null) {
      return newNode;
    }
    var pushed = node.push();

    if (newNode.priority > pushed.priority) {
      var res = _split(pushed, newNode.start);
      return newNode.withChildren(res.$1, res.$2);
    }

    if (newNode.start <= pushed.start) {
      return pushed.withChildren(_insertRec(pushed.left, newNode), pushed.right);
    } else {
      return pushed.withChildren(pushed.left, _insertRec(pushed.right, newNode));
    }
  }

  (IntervalNode<T>?, IntervalNode<T>?) _split(IntervalNode<T>? node, int key) {
    if (node == null) {
      return (null, null);
    }
    var pushed = node.push();
    if (pushed.start < key) {
      var res = _split(pushed.right, key);
      return (pushed.withChildren(pushed.left, res.$1), res.$2);
    } else {
      var res = _split(pushed.left, key);
      return (res.$1, pushed.withChildren(res.$2, pushed.right));
    }
  }

  IntervalNode<T>? _merge(IntervalNode<T>? left, IntervalNode<T>? right) {
    if (left == null) {
      return right;
    }
    if (right == null) {
      return left;
    }
    var lPushed = left.push();
    var rPushed = right.push();
    if (lPushed.priority > rPushed.priority) {
      return lPushed.withChildren(lPushed.left, _merge(lPushed.right, rPushed));
    } else {
      return rPushed.withChildren(_merge(lPushed, rPushed.left), rPushed.right);
    }
  }

  /// Removes all intervals overlapping `[editStart, editEnd)` and shifts subsequent intervals.
  void applyEdit(int editStart, int editEnd, int deltaLength) {
    root = _removeOverlapping(root, editStart, editEnd);

    // Shift remaining intervals that start >= editStart
    if (deltaLength != 0) {
      var s = _split(root, editStart);
      var shiftedRight = s.$2?.withShift(deltaLength);
      root = _merge(s.$1, shiftedRight);
    }
  }

  IntervalNode<T>? _removeOverlapping(IntervalNode<T>? node, int editStart, int editEnd) {
    if (node == null) {
      return null;
    }
    var pushed = node.push();

    if (pushed.maxEnd <= editStart) {
      return pushed;
    }

    if (pushed.start >= editEnd) {
      var newLeft = _removeOverlapping(pushed.left, editStart, editEnd);
      return pushed.withChildren(newLeft, pushed.right);
    }

    var newLeft = _removeOverlapping(pushed.left, editStart, editEnd);
    var newRight = _removeOverlapping(pushed.right, editStart, editEnd);

    bool overlaps = pushed.start < editEnd && pushed.end > editStart;
    if (overlaps) {
      return _removeOverlapping(_merge(newLeft, newRight), editStart, editEnd);
    } else {
      return pushed.withChildren(newLeft, newRight);
    }
  }

  /// Finds all cached parse results that overlap with an edit at character [k].
  List<T> findOverlapping(int k) {
    var out = <T>[];
    _findOverlappingRec(root, k, out);
    return out;
  }

  void _findOverlappingRec(IntervalNode<T>? node, int k, List<T> out) {
    if (node == null) {
      return;
    }
    var pushed = node.push();
    if (pushed.maxEnd <= k) {
      return;
    }

    if (pushed.start <= k && pushed.end > k) {
      out.add(pushed.result);
    }

    if (pushed.left != null) {
      _findOverlappingRec(pushed.left, k, out);
    }

    if (pushed.start <= k && pushed.right != null) {
      _findOverlappingRec(pushed.right, k, out);
    }
  }

  /// Finds all cached parse results that start exactly at the given [pos].
  List<IntervalNode<T>> findStartingAt(int pos) {
    var out = <IntervalNode<T>>[];
    _findStartingAtRec(root, pos, out);
    return out;
  }

  void _findStartingAtRec(IntervalNode<T>? node, int pos, List<IntervalNode<T>> out) {
    if (node == null) {
      return;
    }
    var pushed = node.push();

    if (pushed.start == pos) {
      out.add(pushed);
      _findStartingAtRec(pushed.left, pos, out);
      _findStartingAtRec(pushed.right, pos, out);
    } else if (pos < pushed.start) {
      _findStartingAtRec(pushed.left, pos, out);
    } else {
      _findStartingAtRec(pushed.right, pos, out);
    }
  }

  /// Finds the interval node with the largest `start` such that `start <= pos`.
  ///
  /// Runs in O(log N) average time on the treap.
  IntervalNode<T>? findLastStartingAtOrBefore(int pos) {
    IntervalNode<T>? current = root;
    IntervalNode<T>? best;

    while (current != null) {
      var pushed = current.push();
      if (pushed.start <= pos) {
        best = pushed;
        current = pushed.right;
      } else {
        current = pushed.left;
      }
    }

    return best;
  }

  void dump() {
    print("IntervalTree dump:");
    _dumpRec(root, 0);
  }

  void _dumpRec(IntervalNode<T>? node, int indent) {
    if (node == null) {
      return;
    }
    var pushed = node.push();
    _dumpRec(pushed.left, indent + 2);
    var res = pushed.result;
    var info = "";
    if (res is CachedRuleResult) {
      var crr = res as CachedRuleResult;
      info = " sym=${crr.symbol} prec=${crr.precedenceLevel}";
    }
    print("${" " * indent}[${pushed.start}, ${pushed.end}) maxEnd=${pushed.maxEnd}$info");
    _dumpRec(pushed.right, indent + 2);
  }

  /// Returns a shallow copy of the tree. Since nodes are immutable, this is O(1).
  IntervalTree<T> copy() {
    return IntervalTree<T>(root);
  }
}
