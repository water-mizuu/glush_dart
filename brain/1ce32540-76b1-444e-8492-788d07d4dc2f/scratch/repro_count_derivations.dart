import "package:glush/src/core/list.dart";

void main() {
  print("Testing LazyReturn sharing failure...");
  var leaf = const LazyGlushList<int>.empty().add(const ConstantLazyVal(1));
  var r1 = LazyReturn(() => leaf);

  // We want to avoid identity collapse in branched() to test memoization
  // But LazyGlushList.branched hides the constructor.
  // We can use LazyConcat or something else to hit it twice if it's shared.

  var branch1 = const LazyGlushList<int>.empty().addList(r1);
  var branch2 = const LazyGlushList<int>.empty()
      .addList(const LazyGlushList<int>.empty().add(const ConstantLazyVal(2)))
      .addList(r1);

  // branch1 = [1]
  // branch2 = [2, 1]
  var root = LazyGlushList.branched(branch1, branch2);

  print("Branch1 count: ${branch1.countDerivations()}");
  print("Branch2 count: ${branch2.countDerivations()}");
  print("Root count: ${root.countDerivations()} (expected 2)");

  print("\nTesting LazyEvaluated sharing failure...");
  var concrete = const GlushList<int>.empty().add(1);
  var ev = LazyEvaluated(concrete);
  var rEv = LazyGlushList.branched(
    const LazyGlushList<int>.empty().addList(ev),
    const LazyGlushList<int>.empty().add(const ConstantLazyVal(2)).addList(ev),
  );
  print("Evaluated Root count: ${rEv.countDerivations()} (expected 2)");
}
