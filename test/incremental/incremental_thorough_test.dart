import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Incremental Thorough Tests", () {
    test("Identity Validation: Incremental match equals cold match", () {
      var parser =
          r"""
        start = item+;
        item = 'a'+ 'b';
      """
              .toSMParser();

      var input =
          "ab"
          "aaab"
          "aab";
      var state = parser.createParseState(captureTokensAsMarks: true);
      state.positionManager = FingerTree.leaf(input);

      // Run initial parse
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isTrue, reason: "Initial parse should accept");

      // Perform an edit: "aaab" -> "ab" at position 2
      // Resulting text: "ab" + "ab" + "aab" = "ababaab" (7 chars)
      var nextState = state.applyEdit(2, 6, "ab");
      while (nextState.hasPendingWork &&
          nextState.position < nextState.positionManager.charLength) {
        nextState.processNextToken();
      }
      var finalStep = nextState.finish();

      if (!finalStep.accept) {
        print("Incremental parse FAILED at position ${nextState.position}");
        print("Input: ${nextState.positionManager}");
        print("Pending work: ${nextState.hasPendingWork}");
        print("Frames: ${nextState.frames}");
        print("GlobalWaitlist: ${nextState.globalWaitlist.keys}");
      }

      expect(nextState.accept, isTrue);

      // Cold parse for comparison
      var coldParser =
          r"""
        start = item+;
        item = 'a'+ 'b';
      """
              .toSMParser();
      var coldResult = coldParser.parseAmbiguous("ababaab", captureTokensAsMarks: true);
      expect(coldResult, isA<ParseAmbiguousSuccess>());

      var incPaths = nextState.forest!.allMarkPaths().toList();
      var coldPaths = (coldResult as ParseAmbiguousSuccess).forest.allMarkPaths().toList();

      expect(incPaths.length, equals(coldPaths.length));

      // Compare evaluateStructure results to ensure semantic integrity
      for (var i = 0; i < incPaths.length; i++) {
        var incEval = incPaths[i].evaluateStructure("ababaab").toString();
        var coldEval = coldPaths[i].evaluateStructure("ababaab").toString();
        expect(incEval, equals(coldEval));
      }
    });

    test("Multiple Sequential Edits", () {
      var parser = r"S = 'a'+;".toSMParser();
      var state = parser.createParseState();
      state.positionManager = FingerTree.leaf("aaaaa");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isTrue);

      // Edit 1: aaaaa -> aaabaa (insert 'b' at index 3)
      state = state.applyEdit(3, 3, "b");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isFalse); // 'b' not in grammar

      // Edit 2: aaabaa -> aaaaaa (replace 'b' with 'a')
      state = state.applyEdit(3, 4, "a");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isTrue);
      expect(state.positionManager.toString(), equals("aaaaaa"));
    });

    test("Forest Evaluation Consistency after multiple edits", () {
      var parser =
          r"""
        S = $expr expr;
        expr = $add left:expr '+' right:term | term;
        term = $mul left:term '*' right:atom | atom;
        atom = $num [0-9]+;
      """
              .toSMParser();

      var state = parser.createParseState(captureTokensAsMarks: true);
      state.positionManager = FingerTree.leaf("1+2*3");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();

      // Edit: 1+2*3 -> 1+22*3
      state = state.applyEdit(3, 3, "2"); // Result: "1+22*3"
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();

      var paths = state.forest!.allMarkPaths().toList();
      expect(paths.length, equals(1));
      var structure = paths.single.evaluateStructure("1+22*3").toString();
      expect(structure, contains("num"));
    });

    test("Predicate Invalidation", () {
      // AND predicate: S = &Target 'a' 'b' 'c'
      var parser =
          r"""
        S = &Target 'a' 'b' 'c';
        Target = 'a' 'b';
      """
              .toSMParser();

      var state = parser.createParseState();
      state.positionManager = FingerTree.leaf("abc");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isTrue);

      // Edit: abc -> acc (changes 'b' to 'c' at pos 1)
      // This should invalidate the AND predicate for 'Target' starting at 0.
      state = state.applyEdit(1, 2, "c");
      while (state.hasPendingWork && state.position < state.positionManager.charLength) {
        state.processNextToken();
      }
      state.finish();
      expect(state.accept, isFalse);
    });
  });
}
