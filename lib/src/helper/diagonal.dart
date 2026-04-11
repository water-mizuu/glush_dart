/// Computes the diagonal of two iterables.
///
/// This ensures that values from both iterables are interleaved, which is
/// useful when one or both iterables are infinite.
///
/// For example, if we have two infinite iterables:
/// `L = [l1, l2, l3, ...]`
/// `R = [r1, r2, r3, ...]`
///
/// A nested loop `for (var l in L) for (var r in R)` would never finish the
/// first `l` if `R` is infinite.
///
/// Diagonalization visits pairs (l, r) in increasing order of the sum of their indices:
/// (l1, r1)
/// (l2, r1), (l1, r2)
/// (l3, r1), (l2, r2), (l1, r3)
/// ...
Iterable<(L, R)> diagonalize<L, R>(Iterable<L> left, Iterable<R> right) sync* {
  var leftIterator = left.iterator;
  var rightIterator = right.iterator;

  var leftValues = <L>[];
  var rightValues = <R>[];

  bool leftDone = false;
  bool rightDone = false;

  for (int sum = 0; ; sum++) {
    // Try to get next left value if needed
    if (!leftDone && leftValues.length <= sum) {
      if (leftIterator.moveNext()) {
        leftValues.add(leftIterator.current);
      } else {
        leftDone = true;
      }
    }

    // Try to get next right value if needed
    if (!rightDone && rightValues.length <= sum) {
      if (rightIterator.moveNext()) {
        rightValues.add(rightIterator.current);
      } else {
        rightDone = true;
      }
    }

    if (leftDone && rightDone && sum >= leftValues.length + rightValues.length - 2) {
      break;
    }

    bool yielded = false;
    // Visit all pairs (i, j) such that i + j == sum
    for (int i = 0; i <= sum; i++) {
      int j = sum - i;
      if (i < leftValues.length && j < rightValues.length) {
        yield (leftValues[i], rightValues[j]);
        yielded = true;
      }
    }

    if (!yielded && leftDone && rightDone) {
      break;
    }
  }
}
