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
      var branched = GlushList.branched(l1, l2);

      expect(branched, equals(l1));
      expect(branched is! BranchedList, isTrue);
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
      expect(list.allPaths().first, equals([1, 2, 3]));
    });
  });
}
