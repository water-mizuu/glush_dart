import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Incremental Reuse", () {
    test("reuses cached results in a sequence after a trailing edit", () {
      GlushProfiler.enabled = true;
      
      // Use a fixed-length part to eliminate ambiguity.
      var p5 = Pattern.char("a") >> Pattern.char("a") >> Pattern.char("a") >> Pattern.char("a") >> Pattern.char("a");
      var part = Rule("part", () => p5);
      
      // top matches exactly 3 parts (15 'a's)
      var top = Rule("top", () => part.call() >> part.call() >> part.call());
      
      var grammar = Grammar(() => top);
      var parser = SMParser(grammar);
      
      var input = "aaaaa" "aaaaa" "aaaaa"; // 15 'a's
      var state = parser.createParseState();
      state.positionManager = FingerTree.leaf(input);
      
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      
      // Edit the LAST part: change "aaaaa" to "aaaba"
      // Position 13 is the 4th 'a' in the 3rd part.
      var nextState = state.applyEdit(13, 14, "b"); 
      
      print("IntervalIndex after edit:");
      nextState.previousIntervalIndex!.dump();

      GlushProfiler.reset();
      while (nextState.hasPendingWork && nextState.position < nextState.positionManager.charLength) {
        nextState.processNextToken();
      }
      nextState.finish();
      
      var counters = GlushProfiler.snapshot().counters;
      var hits = counters["parser.rule_calls.papa_carlo_fast_forward"] ?? 0;
      print("Sequence hits: $hits");
      
      // Now we expect exactly 2 hits for 'part' at 0 and 5.
      // 'top' at 0 will be a MISS because its only cached interval [0, 15) was removed.
      expect(hits, greaterThanOrEqualTo(2));
    });
  });
}
