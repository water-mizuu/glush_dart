import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
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
      list.forEach(result.add);
      expect(result, equals([1, 2]));
    });

    test("Structural equality works", () {
      var l1 = const GlushList<int>.empty().add(1).add(2);
      var l2 = const GlushList<int>.empty().add(1).add(2);
      expect(l1, equals(l2));
      expect(l1.hashCode, equals(l2.hashCode));
      // They might not be identical without interning, which is fine now.
    });

    test("FragmentList creation and equality", () {
      var l1 = const GlushList<int>.empty().add(1).add(2);
      expect(l1 is Push, isTrue);

      var l2 = const GlushList<int>.empty().add(1).add(2);
      expect(l1, equals(l2));
    });

    test("BranchedList deduplicates alternatives structurally", () {
      var l1 = const GlushList<int>.empty().add(1);
      var l2 = const GlushList<int>.empty().add(1);
      var branched = GlushList.branched([l1, l2]);

      expect(branched, equals(l1));
      expect(branched is! BranchedList, isTrue);
    });

    test("Concat joins two lists", () {
      var l1 = const GlushList<int>.empty().add(1);
      var l2 = const GlushList<int>.empty().add(2);
      var concat = l1.addList(l2);
      var result = <int>[];
      concat.forEach(result.add);
      expect(result, equals([1, 2]));
    });

    test("toList converts to standard list", () {
      var list = const GlushList<int>.empty().add(1).add(2).add(3);
      expect(list.toList(), equals([1, 2, 3]));
    });

    test("derivationCount handles branching and concat", () {
      var l = const GlushList<int>.empty().add(1).add(2);
      expect(l.derivationCount, equals(1));

      var b = GlushList.branched([
        const GlushList<int>.empty().add(1),
        const GlushList<int>.empty().add(2),
      ]);
      expect(b.derivationCount, equals(2));

      var c = b.addList(b); // (1 | 2) followed by (1 | 2) = 4 combinations
      expect(c.derivationCount, equals(4));
    });
  });

  group("GlushList Conjunction", () {
    test("derivationCount handles ConjunctionMark Cartesian product", () {
      var branch1 = GlushList.branched([
        const GlushList<Mark>.empty().add(const StringMark("a", 0)),
        const GlushList<Mark>.empty().add(const StringMark("A", 0)),
      ]);
      var branch2 = GlushList.branched([
        const GlushList<Mark>.empty().add(const StringMark("b", 0)),
        const GlushList<Mark>.empty().add(const StringMark("B", 0)),
      ]);

      // A conjunction of two branches with 2 derivations each = 2 * 2 = 4 derivations
      var conjMark = ConjunctionMark([branch1, branch2], 0);
      var list = const GlushList<Mark>.empty().add(conjMark);

      expect(list.derivationCount, equals(4));

      // Nested expansion: parent with 2 derivs * conj with 4 derivs = 8
      var parent = GlushList.branched([
        const GlushList<Mark>.empty().add(const NamedMark("p1", 0)),
        const GlushList<Mark>.empty().add(const NamedMark("p2", 0)),
      ]);
      var nested = parent.add(conjMark);
      expect(nested.derivationCount, equals(8));
    });
  });
}
