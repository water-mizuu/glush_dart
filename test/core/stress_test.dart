import "package:glush/src/core/list.dart";
import "package:test/test.dart";

void main() {
  group("GlushList Stress Tests", () {
    test("Deep Push chain does not stack overflow", () {
      const depth = 50000;
      var list = const GlushList<int>.empty();
      for (var i = 0; i < depth; i++) {
        list = list.add(i);
      }

      var count = 0;
      list.iterate().forEach((e) {
        expect(e, equals(count));
        count++;
      });
      expect(count, equals(depth));
    });

    test("Wide BranchedList does not stack overflow", () {
      const width = 10000;
      var alternatives = <GlushList<int>>[];
      for (var i = 0; i < width; i++) {
        alternatives.add(const GlushList<int>.empty().add(i));
      }

      var branched = alternatives.fold(const GlushList<int>.empty(), GlushList.branched);
      var results = <int>[];
      branched.iterate().forEach(results.add);

      expect(results.length, equals(width));
      for (var i = 0; i < width; i++) {
        expect(results[i], equals(i));
      }
    });

    test("Complex nested structure does not stack overflow", () {
      // Create a structure with nested Concat and BranchedList
      // (A + B) + (C + D) ...
      GlushList<int> build(int depth) {
        if (depth == 0) {
          return const GlushList<int>.empty().add(1);
        }
        return build(depth - 1).addList(build(depth - 1));
      }

      // depth 15 => 2^15 elements = 32768
      var list = build(15);
      var count = 0;
      list.iterate().forEach((e) => count++);
      expect(count, equals(1 << 15));
    });
  });
}
