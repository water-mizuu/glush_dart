import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Conjunction Edge Cases", () {
    test("Triple Intersection (A & B & C)", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var l1 = Label("l1", a);
        var l2 = Label("l2", a);
        var l3 = Label("l3", a);

        // (l1:a & l2:a) & l3:a
        return Rule("test", () => (l1 & l2) & l3);
      });

      var parser = SMParser(grammar);
      var input = "a";
      expect(parser.recognize(input), isTrue);

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.toList().evaluateStructure();

      expect(root.get("l1"), isNotEmpty);
      expect(root.get("l2"), isNotEmpty);
      expect(root.get("l3"), isNotEmpty);
      expect(root.span, equals("a"));
    });

    test("Ambiguous Intersection (Ambiguous & Non-Ambiguous)", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        // (a l1:a | a l2:a) & (a a)
        var left = (a >> Label("l1", a)) | (a >> Label("l2", a));
        var right = a >> a;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);
      var input = "aa";

      expect(parser.recognize(input), isTrue);
      expect(parser.countAllParses(input), equals(2));

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;

      // Since it's ambiguous at the top level (two ways to match 'left'),
      // forest.toList() will have two top-level branches if we use allPaths.
      // But wait! ConjunctionTrackers merge multiple completions for the SAME end position.
      // So if 'left' has 2 ways to match 'aa', then tracker.leftCompletions[2] has 2 mark lists.
      // Cartesian product results in 2 ConjunctionMarks.

      var paths = success.forest.allPaths();
      expect(paths.length, equals(2));

      var results = paths.map((p) => p.evaluateStructure()).toList();
      var l1Recovered = results.any((r) => r.get("l1").isNotEmpty);
      var l2Recovered = results.any((r) => r.get("l2").isNotEmpty);

      expect(l1Recovered, isTrue);
      expect(l2Recovered, isTrue);
    });

    test("Epsilon Conjunction", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var l1 = Label("l1", Eps());
        var l2 = Label("l2", Eps());

        // (l1:eps | a) & (l2:eps | a)
        var left = l1 | a;
        var right = l2 | a;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);

      expect(parser.recognize(""), isTrue);
      // For empty string, (l1:eps | a) can match via l1:eps, and (l2:eps | a) can match via l2:eps.
      // Both produce matches at span (0,0), so conjunction succeeds.
      expect(parser.countAllParses(""), equals(1));

      var res = parser.parseAmbiguous("", captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var forest = success.forest;
      var paths = forest.allPaths();
      print("Forest allPaths: ${paths.length}");
      for (var (i, path) in paths.indexed) {
        print("  Path $i has ${path.length} marks:");
        for (var mark in path) {
          if (mark is ConjunctionMark) {
            print(
              "    - ConjunctionMark @ ${mark.position}: left=${mark.branches[0].runtimeType}, right=${mark.branches[1].runtimeType}",
            );
          } else {
            print("    - ${mark.runtimeType}");
          }
        }
      }
      var root = forest.toList().evaluateStructure();
      print("Final result: $root");
      expect(root.get("l1"), isNotEmpty, reason: "l1 should be captured even though epsilon");
      expect(root.get("l2"), isNotEmpty, reason: "l2 should be captured even though epsilon");
      expect(root.span, equals(""));

      // For input "a", we have multiple matching paths:
      // 1. left via 'a' (not l1), right via 'a' (not l2) → conjunction produces ConjunctionMark + 'a'
      // 2. left via l1:eps, right via l2:eps → but span is (0,0), 'a' is at (0,1) → mismatch, fails
      // So only path 1 succeeds.
      expect(parser.recognize("a"), isTrue);
    });

    test("Conjunction within Predicate", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");

        // &(a && a) a
        var pred = And(a & a);
        return Rule("test", () => pred >> a);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("b"), isFalse);
    });

    test("Lookahead within Conjunction", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");

        // (a & (&b a))  -- this should fail on 'a' because &b fails.
        // wait! a & (&b a) matches nothing because (&b a) starts with check for 'b' but consumes 'a'.
        var left = a;
        var right = And(b) >> a;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        // (a a) & (a &a a)
        var left = a >> a;
        var right = a >> And(a) >> a;
        return Rule("test", () => left & right);
      });
      var parser2 = SMParser(grammar2);
      expect(parser2.recognize("aa"), isTrue);
    });
    test("5-Deep Conjunction Nesting", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", a);
        var l3 = Label("l3", a);
        var l4 = Label("l4", a);
        var l5 = Label("l5", a);

        // (((l1:a & l2:a) & l3:a) & l4:a) & l5:a
        return Rule("test", () => l1 & l2 & l3 & l4 & l5);
      });

      var parser = SMParser(grammar);
      var input = "a";
      expect(parser.recognize(input), isTrue);

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.toList().evaluateStructure();

      expect(root.get("l1"), isNotEmpty);
      expect(root.get("l2"), isNotEmpty);
      expect(root.get("l3"), isNotEmpty);
      expect(root.get("l4"), isNotEmpty);
      expect(root.get("l5"), isNotEmpty);
      expect(root.span, equals("a"));
    });
    test("Branched Nested Conjunction ((l1 & l2) & (l3 & l4))", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", a);
        var l3 = Label("l3", a);
        var l4 = Label("l4", a);

        // (l1:a & l2:a) & (l3:a & l4:a)
        var left = l1 & l2;
        var right = l3 & l4;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);
      var input = "a";
      expect(parser.recognize(input), isTrue);

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.toList().evaluateStructure();

      expect(root.get("l1"), isNotEmpty);
      expect(root.get("l2"), isNotEmpty);
      expect(root.get("l3"), isNotEmpty);
      expect(root.get("l4"), isNotEmpty);
      expect(root.span, equals("a"));
    });
    test("Left Recursion within Conjunction (S -> (S & a) | a)", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        late Rule S;
        // This is a bit unusual but tests the interaction of GSS and Conjunction
        S = Rule("S", () => (S.call() & a) | a);
        return S;
      });

      var parser = SMParser(grammar);

      expect(parser.recognize("a"), isTrue);
      // 'aa' matches if (S & a) matches 'aa'.
      // S matches 'a'. a matches 'a'.
      // But (S & a) requires both to match the SAME range.
      // S at 0 matches 'a' (0->1). a at 0 matches 'a' (0->1).
      // So (S & a) at 0 matches 'a' (0->1).
      // Thus S at 0 matches 'a' (0->1) via BOTH branches.

      // Can it match 'aa'?
      // To match 'aa', (S & a) must match 'aa'.
      // This requires S(0->2) and a(0->2).
      // But 'a' can only match length 1.
      // So S can only match length 1.
      expect(parser.recognize("aa"), isFalse);
    });

    test("Complex Recursive Conjunction (S -> (a S) & (aa*))", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        late Rule S;
        S = Rule("S", () => (a >> S.call()) | a);
        var combined = Rule("test", () => S.call() & (a >> a.star()));
        return combined;
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("aa"), isTrue);
      expect(parser.recognize("aaa"), isTrue);
    });

    test("Cyclic Conjunction (A -> B & C, B -> A | a, C -> A | a)", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        late Rule A, B, C;
        A = Rule("A", () => B.call() & C.call());
        B = Rule("B", () => A.call() | a);
        C = Rule("C", () => A.call() | a);
        return A;
      });

      var parser = SMParser(grammar);
      // For input 'a':
      // A(0) -> B(0) & C(0)
      // B(0) matches 'a'. C(0) matches 'a'.
      // A(0) matches 'a'.
      expect(parser.recognize("a"), isTrue);

      // For input 'aa': fails because everything only matches 'a'
      expect(parser.recognize("aa"), isFalse);
    });
    test("Extreme Stress: Recursive + Nested Branched Conjunction", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        late Rule S;
        // S -> (l1:a S & l2:a S) | l3:a
        // This intersects two recursive branches each with their own labels
        S = Rule(
          "S",
          () => (Label("l1", a >> S.call()) & Label("l2", a >> S.call())) | Label("l3", a),
        );
        return S;
      });

      var parser = SMParser(grammar);
      var input = "aaa";

      expect(parser.recognize(input), isTrue);

      // Each 'aaa' match has 1 derivation because (l1:a S) and (l2:a S) are both non-ambiguous.
      // But they nesting level is 3 deep.
      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.toList().evaluateStructure();

      // Root (at level 0) should have l1 and l2.
      // l1 should have l1 and l2 (at level 1).
      // and so on.
      expect(root.get("l1"), isNotEmpty);
      expect(root.get("l2"), isNotEmpty);

      var l1Node = root.get("l1").first as ParseResult;
      expect(l1Node.get("l1"), isNotEmpty);
      expect(l1Node.get("l2"), isNotEmpty);

      expect(root.span, equals("aaa"));
    });

    test("Optional within Conjunction (Optional(label) & label)", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", a);

        // (l1:a)? & l2:a
        // For input "a":
        //   (l1:a)? matches "a" via l1, then l2:a matches "a".
        //   They must match the same span: (0,1). Both do.
        //   So conjunction succeeds.
        //   Result should have l1="a" and l2="a".

        var left = l1.opt();
        var right = l2;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);

      // "a" should match
      expect(parser.recognize("a"), isTrue);

      var res = parser.parseAmbiguous("a", captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.toList().evaluateStructure();

      expect(root.get("l1"), isNotEmpty, reason: "l1 should be captured");
      expect(root.get("l2"), isNotEmpty, reason: "l2 should be captured");
      expect(root.span, equals("a"));

      // Empty string: (l1:a)? matches "" (epsilon), l2:a matches...nothing.
      // So conjunction fails because empty span ≠ next position after parse.
      expect(parser.recognize(""), isFalse);
    });

    test("Asymmetric Conjunction (Optional & Non-optional)", () {
      var a = Pattern.char("a");
      var b = Pattern.char("b");
      var grammar = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", b);

        // (l1:a)? & l2:b
        // For "b": (l1:a)? at 0 matches "" (epsilon), l2:b at 0 matches "b" (span 0->1).
        // Asymmetric spans: epsilon (0,0) vs (0,1) → conjunction fails.

        var left = l1.opt();
        var right = l2;
        return Rule("test", () => left & right);
      });

      var parser = SMParser(grammar);

      // "b" alone should fail (asymmetric spans)
      expect(parser.recognize("b"), isFalse);

      var grammar2 = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", b);

        // (l1:a)? & (l2:b)?
        // For input "a":
        //   - (l1:a)? matches "a" via l1
        //   - (l2:b)? fails to match "a", but as optional it matches empty
        //   - Asymmetric spans (0->1) vs (0->0), so conjunction fails.
        // For input "":
        //   - Both match empty (0->0), so conjunction succeeds.

        var left = l1.opt();
        var right = l2.opt();
        return Rule("test", () => left & right);
      });

      var parser2 = SMParser(grammar2);

      // Only empty string should match (both optionals match empty span)
      expect(parser2.recognize(""), isTrue);
      expect(
        parser2.recognize("a"),
        isFalse,
      ); // (l1:a)? matches "a", (l2:b)? matches empty → asymmetric
      expect(
        parser2.recognize("b"),
        isFalse,
      ); // (l1:a)? matches empty, (l2:b)? matches "b" → asymmetric
    });
  });
}
