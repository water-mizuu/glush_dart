import "package:glush/glush.dart";
import "package:test/test.dart";

Set<String> getLabels(ParseResult result) {
  return result.children.map((entry) => entry.$1).toSet();
}

void main() {
  group("Conjunction Epsilon Reproduction", () {
    test("Case 0: (a:'' | '') - Non-transparent Label eliminates epsilon paths", () {
      var grammar = Grammar(() {
        var a = Label("a", Eps());
        var left = a | Eps();
        return Rule("S", () => left);
      });

      var parser = SMParser(grammar);
      var res = parser.parseAmbiguous("");
      expect(res, isA<ParseAmbiguousSuccess>());

      var success = res as ParseAmbiguousSuccess;
      var paths = success.forest.allMarkPaths().toList();
      expect(
        paths.length,
        equals(1),
        reason:
            "Non-transparent Label makes epsilon alternatives invisible. "
            "Only labeled path {a} remains.",
      );

      var results = paths.map((p) => p.evaluateStructure("")).toList();
      var labels = results.map((r) => getLabels(r)).toList();

      expect(labels.every((l) => l.contains("a")), isTrue, reason: "All paths must have label 'a'");
    });

    test("Case 1: (a:'' | '') && eps() - Conjunction with non-transparent Label", () {
      var grammar = Grammar(() {
        var a = Label("a", Eps());
        var left = a | Eps();
        return Rule("S", () => left & Eps());
      });

      var parser = SMParser(grammar);
      var res = parser.parseAmbiguous("");
      expect(res, isA<ParseAmbiguousSuccess>());

      var success = res as ParseAmbiguousSuccess;
      var paths = success.forest.allMarkPaths().toList();
      expect(
        paths.length,
        equals(1),
        reason:
            "Non-transparent Label eliminates epsilon alternatives from left. "
            "Conjunction requires both sides, so only {a} remains.",
      );

      var results = paths.map((p) => p.evaluateStructure("")).toList();
      var labels = results.map((r) => getLabels(r)).toList();

      expect(labels.every((l) => l.contains("a")), isTrue, reason: "Path must have label 'a'");
    });

    test("Case 2: (a:'' | '') && (b:'') - CRITICAL: Both sides must succeed", () {
      var grammar = Grammar(() {
        var a = Label("a", Eps());
        var b = Label("b", Eps());
        var left = a | Eps();
        var right = b;
        return Rule("S", () => left & right);
      });

      var parser = SMParser(grammar);
      var res = parser.parseAmbiguous("", captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());

      var success = res as ParseAmbiguousSuccess;
      var paths = success.forest.allMarkPaths().toList();
      expect(
        paths.length,
        equals(2),
        reason:
            "Exactly 2 valid paths: {a,b} and {b}. "
            "Path {a} alone is INVALID because right side must also succeed.",
      );

      var results = paths.map((p) => const StructuredEvaluator().evaluate(p, input: "")).toList();
      var labels = results.map((r) => getLabels(r)).toList();

      expect(
        labels.any((l) => l.contains("a") && l.contains("b")),
        isTrue,
        reason: "Must have path with both a and b",
      );
      expect(
        labels.any((l) => !l.contains("a") && l.contains("b")),
        isTrue,
        reason: "Must have path with only b (left side epsilon)",
      );
      expect(
        labels.any((l) => l.contains("a") && !l.contains("b")),
        isFalse,
        reason: "Path with only a is INVALID - right side must also succeed",
      );
    });

    test("Case 3: (a:'' | '') && (b:'' | '') - Cartesian with non-transparent Labels", () {
      var grammar = Grammar(() {
        var a = Label("a", Eps());
        var b = Label("b", Eps());
        var left = a | Eps();
        var right = b | Eps();
        return Rule("S", () => left & right);
      });

      var parser = SMParser(grammar);
      var res = parser.parseAmbiguous("", captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());

      var success = res as ParseAmbiguousSuccess;
      var paths = success.forest.allMarkPaths().toList();
      expect(
        paths.length,
        equals(3),
        reason:
            "3 paths (not 4) because non-transparent Labels eliminate "
            "pure epsilon paths. Missing: {} (both epsilon)",
      );

      var results = paths.map((p) => const StructuredEvaluator().evaluate(p, input: "")).toList();
      var labels = results.map((r) => getLabels(r)).toList();

      // 3 combinations exist (both-epsilon path is eliminated)
      expect(
        labels.any((l) => l.contains("a") && l.contains("b")),
        isTrue,
        reason: "Must have path {a, b}",
      );
      expect(
        labels.any((l) => l.contains("a") && !l.contains("b")),
        isTrue,
        reason: "Must have path {a}",
      );
      expect(
        labels.any((l) => !l.contains("a") && l.contains("b")),
        isTrue,
        reason: "Must have path {b}",
      );
      expect(
        labels.any((l) => !l.contains("a") && !l.contains("b")),
        isFalse,
        reason: "Path {} should NOT exist (both epsilon eliminated by non-transparent Label)",
      );
    });
  });
}
