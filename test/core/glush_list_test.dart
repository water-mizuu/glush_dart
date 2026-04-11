import "package:glush/src/core/list.dart";
import "package:test/test.dart";

void main() {
  group("GlushList", () {
    test("EmptyList is singleton-like", () {
      expect(const GlushList<int>.empty(), equals(const GlushList<int>.empty()));
      expect(identical(const GlushList<int>.empty(), const GlushList<int>.empty()), isTrue);
    });

    test("Push creates a list", () {
      var list = const GlushList<int>.empty().add(1).add(2);
      var result = <int>[];
      list.iterate().forEach(result.add);
      expect(result, equals([1, 2]));
    });

    test("Identity-based lists are distinct instances", () {
      var l1 = const GlushList<int>.empty().add(1).add(2);
      var l2 = const GlushList<int>.empty().add(1).add(2);
      // After removing structural equality, non-identical instances are not equal.
      expect(identical(l1, l2), isFalse);
      // But their contents are equivalent.
      expect(l1.iterate().toList(), equals(l2.iterate().toList()));
    });

    test("FragmentList creation and value equivalence", () {
      var l1 = const GlushList<int>.empty().add(1).add(2);
      expect(l1 is Push, isTrue);

      var l2 = const GlushList<int>.empty().add(1).add(2);
      // Identity-based: distinct instances, same content.
      expect(l1.iterate().toList(), equals(l2.iterate().toList()));
    });

    test("BranchedList deduplicates alternatives by identity", () {
      var l1 = const GlushList<int>.empty().add(1);
      // Same instance used twice => identity dedup collapses to l1
      var branched = GlushList.branched(l1, l1);
      expect(identical(branched, l1), isTrue);
      expect(branched is! BranchedList, isTrue);

      // Different instances with same content => NOT deduped
      var l2 = const GlushList<int>.empty().add(1);
      var branched2 = GlushList.branched(l1, l2);
      expect(branched2 is BranchedList, isTrue);
    });

    test("Concat joins two lists", () {
      var l1 = const GlushList<int>.empty().add(1);
      var l2 = const GlushList<int>.empty().add(2);
      var concat = l1.addList(l2);
      var result = <int>[];
      concat.iterate().forEach(result.add);
      expect(result, equals([1, 2]));
    });

    test("toList converts to standard list", () {
      var list = const GlushList<int>.empty().add(1).add(2).add(3);
      expect(list.allMarkPaths().first, equals([1, 2, 3]));
    });
  });

  group("LazyGlushList", () {
    test("LazyGlushList defers evaluation and memoizes", () {
      var callCount = 0;
      var lazy = const LazyGlushList<int>.empty().add(
        ClosureVal(() {
          callCount++;
          return 1;
        }),
      );

      expect(callCount, equals(0));
      var evaluated = lazy.evaluate();
      expect(callCount, equals(1));
      expect(evaluated.iterate().toList(), equals([1]));

      // Memoization check
      lazy.evaluate();
      expect(callCount, equals(1));
    });

    test("Complex lazy structure evaluation", () {
      var l1 = const LazyGlushList<int>.empty().add(const ConstantLazyVal(1));
      var l2 = const LazyGlushList<int>.empty().add(const ConstantLazyVal(2));
      var branched = LazyGlushList.branched(l1, l2);
      var concat = branched.addList(const LazyGlushList<int>.empty().add(const ConstantLazyVal(3)));

      var evaluated = concat.evaluate();
      var paths = evaluated.allMarkPaths().toList();
      expect(paths.length, equals(2));
      expect(paths[0], equals([1, 3]));
      expect(paths[1], equals([2, 3]));
    });

    test("Deep nested lazy lists do not stack overflow on isEmpty", () {
      LazyGlushList<int> list = const LazyGlushList<int>.empty();
      // 5000 nodes deep should be enough to trigger overflow if recursive
      for (var i = 0; i < 5000; i++) {
        list = LazyGlushList.branched(
          list,
          const LazyGlushList<int>.empty().add(ConstantLazyVal(i)),
        );
      }
      expect(list.isEmpty, isFalse);
    });
  });
}
