import "dart:math" show Random;

final _random = Random();

/// An immutable, weight-balanced Rope (Implicit Treap) used for O(log N)
/// character-level position shifting and pull-based scannerless lookups.
///
/// Despite the name `FingerTree` (kept for compatibility), this is implemented
/// as a randomized Binary Rope to optimize `split` and `concat` operations.
class FingerTree {
  const FingerTree.empty() : priority = 0, charLength = 0, left = null, right = null, text = null;

  FingerTree._(this.priority, this.charLength, this.left, this.right, this.text);

  factory FingerTree.leaf(String text) {
    if (text.isEmpty) {
      return const FingerTree.empty();
    }
    return FingerTree._(_random.nextInt(1 << 31), text.length, null, null, text);
  }
  final int priority;
  final int charLength;
  final FingerTree? left;
  final FingerTree? right;
  final String? text;

  /// Concatenates this tree with another tree in O(log N) time.
  FingerTree concat(FingerTree other) {
    if (charLength == 0) {
      return other;
    }
    if (other.charLength == 0) {
      return this;
    }
    return _merge(this, other)!;
  }

  /// Replaces a range of characters with [replacement].
  ///
  /// This fast path avoids split/concat churn when the tree is a single leaf,
  /// which is the common case for incremental microbenchmarks.
  FingerTree replaceRange(int start, int end, String replacement) {
    if (start <= 0 && end >= charLength && text != null) {
      return FingerTree.leaf(replacement);
    }

    if (text != null && start >= 0 && end <= charLength) {
      var replaced = text!.replaceRange(start, end, replacement);
      return FingerTree.leaf(replaced);
    }

    var (left, middleAndRight) = split(start);
    var (_, right) = middleAndRight.split(end - start);
    return left.concat(FingerTree.leaf(replacement)).concat(right);
  }

  /// Splits this tree into two trees at the given character index in O(log N) time.
  (FingerTree, FingerTree) split(int index) {
    if (index <= 0) {
      return (const FingerTree.empty(), this);
    }
    if (index >= charLength) {
      return (this, const FingerTree.empty());
    }
    var (l, r) = _split(this, index);
    return (l ?? const FingerTree.empty(), r ?? const FingerTree.empty());
  }

  /// Retrieves the character code at the given index in O(log N) time.
  int? charCodeAt(int index) {
    if (index < 0 || index >= charLength) {
      return null;
    }
    return _charCodeAtRec(this, index);
  }

  static int _charCodeAtRec(FingerTree node, int index) {
    if (node.text != null) {
      return node.text!.codeUnitAt(index);
    }
    int leftLen = node.left?.charLength ?? 0;
    if (index < leftLen) {
      return _charCodeAtRec(node.left!, index);
    } else {
      return _charCodeAtRec(node.right!, index - leftLen);
    }
  }

  static FingerTree? _merge(FingerTree? a, FingerTree? b) {
    if (a == null || a.charLength == 0) {
      return b;
    }
    if (b == null || b.charLength == 0) {
      return a;
    }

    if (a.priority > b.priority) {
      if (a.text != null) {
        // a is a leaf. We can't make it root of b.
        // Just create a new internal node.
        return FingerTree._(a.priority, a.charLength + b.charLength, a, b, null);
      }
      return FingerTree._(
        a.priority,
        a.charLength + b.charLength,
        a.left,
        _merge(a.right, b),
        null,
      );
    } else {
      if (b.text != null) {
        // b is a leaf.
        return FingerTree._(b.priority, a.charLength + b.charLength, a, b, null);
      }
      return FingerTree._(
        b.priority,
        a.charLength + b.charLength,
        _merge(a, b.left),
        b.right,
        null,
      );
    }
  }

  static (FingerTree?, FingerTree?) _split(FingerTree? node, int index) {
    if (node == null || node.charLength == 0) {
      return (null, null);
    }

    if (node.text != null) {
      if (index <= 0) {
        return (null, node);
      }
      if (index >= node.charLength) {
        return (node, null);
      }
      var lStr = node.text!.substring(0, index);
      var rStr = node.text!.substring(index);
      return (FingerTree.leaf(lStr), FingerTree.leaf(rStr));
    }

    int leftLen = node.left?.charLength ?? 0;
    if (index <= leftLen) {
      var (l, r) = _split(node.left, index);
      return (l, _merge(r, node.right));
    } else {
      var (l, r) = _split(node.right, index - leftLen);
      return (_merge(node.left, l), r);
    }
  }

  @override
  String toString() {
    if (text != null) {
      return text!;
    }
    return (left?.toString() ?? "") + (right?.toString() ?? "");
  }
}
