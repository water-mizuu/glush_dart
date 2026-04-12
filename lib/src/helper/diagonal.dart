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
Iterable<(L, R)> diagonalize<L, R>(Iterable<L> left, Iterable<R> right) =>
    _DiagonalizingIterable(left, right);

class _DiagonalizingIterable<L, R> with Iterable<(L, R)> {
  const _DiagonalizingIterable(this.left, this.right);
  final Iterable<L> left;
  final Iterable<R> right;

  @override
  Iterator<(L, R)> get iterator => _DiagonalizingIterator(left.iterator, right.iterator);
}

class _DiagonalizingIterator<L, R> implements Iterator<(L, R)> {
  _DiagonalizingIterator(this.iteratorLeft, this.iteratorRight);

  final Iterator<L> iteratorLeft;
  final Iterator<R> iteratorRight;

  final leftValues = <L>[];
  final rightValues = <R>[];

  var leftDone = false;
  var rightDone = false;

  var sum = -1;
  var currentIndex = -1;

  @override
  (L, R) get current => _current!;

  // ignore: use_late_for_private_fields_and_variables
  (L, R)? _current;

  @override
  bool moveNext() {
    if (leftDone && rightDone && sum >= leftValues.length + rightValues.length - 2) {
      return false;
    }

    currentIndex++;

    // If we've exhausted all pairs for the current sum, move to the next
    if (currentIndex > sum) {
      sum++;
      currentIndex = 0;
    }

    // Find the next valid pair (i, j) such that i + j == sum
    while (sum >= 0) {
      // Try to load more values for the new sum
      if (!leftDone && leftValues.length <= sum) {
        if (iteratorLeft.moveNext()) {
          leftValues.add(iteratorLeft.current);
        } else {
          leftDone = true;
        }
      }

      if (!rightDone && rightValues.length <= sum) {
        if (iteratorRight.moveNext()) {
          rightValues.add(iteratorRight.current);
        } else {
          rightDone = true;
        }
      }

      for (int i = currentIndex; i <= sum; i++) {
        int j = sum - i;
        if (i < leftValues.length && j < rightValues.length) {
          _current = (leftValues[i], rightValues[j]);
          currentIndex = i + 1;
          return true;
        }
      }

      // If no pair found and both iterables are done, we're finished
      if (leftDone && rightDone) {
        return false;
      }

      // Move to the next sum
      sum++;
      currentIndex = 0;
    }

    return false;
  }
}
