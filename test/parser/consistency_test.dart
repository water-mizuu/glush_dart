import "package:glush/glush.dart";
import "package:test/test.dart";

extension on Pattern {
  Pattern operator /(Pattern other) => Alt(this, Seq(not(), other));
}

/// Compares two mark lists for logical equality.
bool markListsEqual(List<Mark> left, List<Mark> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

/// Helper to verify that parse() results are consistent with parseAmbiguous().
void verifyConsistency(Grammar g, String input, {bool isAmbiguous = false}) {
  var parser = SMParserMini(g);
  var result = parser.parse(input);
  var ambigResult = parser.parseAmbiguous(input);

  expect(result, isA<ParseSuccess>(), reason: "Standard parse failed for input: $input");
  expect(
    ambigResult,
    isA<ParseAmbiguousSuccess>(),
    reason: "Ambiguous parse failed for input: $input",
  );

  var standardMarks = (result as ParseSuccess).result.rawMarks;
  var ambigForest = (ambigResult as ParseAmbiguousSuccess).forest;
  var ambigPaths = ambigForest.allPaths().toList();

  if (!isAmbiguous) {
    expect(
      ambigPaths.length,
      1,
      reason: "Expected exactly one path for non-ambiguous grammar: $input",
    );
  }

  // Verify that the standard result's marks are present in the ambiguous set.
  var found = false;
  for (var path in ambigPaths) {
    if (markListsEqual(standardMarks, path)) {
      found = true;
      break;
    }
  }

  expect(
    found,
    isTrue,
    reason:
        "Standard parse marks not found in ambiguous forest paths.\n"
        "Standard: $standardMarks\n"
        "Ambig Paths: $ambigPaths",
  );
}

void main() {
  group("Parser Consistency (parse vs parseAmbiguous)", () {
    test("Linear grammar matching", () {
      var g = Grammar(() => Rule("S", () => Token.char("a") >> Token.char("b")));
      verifyConsistency(g, "ab");
    });

    test("Dual choice matching (Ambiguous Choice)", () {
      var g = Grammar(
        () => Rule("S", () => (Marker("1") >> Token.char("a")) | (Marker("2") >> Token.char("a"))),
      );
      // Even though ambiguous, parse() result must be one of the paths.
      verifyConsistency(g, "a", isAmbiguous: true);

      var parser = SMParserMini(g);
      var ambig = (parser.parseAmbiguous("a") as ParseAmbiguousSuccess).forest;
      expect(
        ambig.allPaths().length,
        2,
        reason: "Expected 2 parallel derivations for Choice(a, a) with distinct markers",
      );
    });

    test("Recursive sequence matching (Ambiguous Sequence)", () {
      // S -> S 'a' | 'a'
      var g = Grammar(() {
        late Rule s;
        s = Rule("S", () => (s() >> Token.char("a")) | Token.char("a"));
        return s;
      });
      // 'aa' matches through ((a)a) or potentially others if grammar was different
      verifyConsistency(g, "aa", isAmbiguous: true);
    });

    test("Conjunction merging consistency", () {
      // S -> ('a' 'b') && ('a' 'b')
      var g = Grammar(
        () => Rule(
          "S",
          () => (Token.char("a") >> Token.char("b")) & (Token.char("a") >> Token.char("b")),
        ),
      );
      verifyConsistency(g, "ab");

      var parser = SMParserMini(g);
      var ambig = (parser.parseAmbiguous("ab") as ParseAmbiguousSuccess).forest;
      // Should have 1 result because both branches are unique and merged.
      expect(ambig.allPaths().length, 1);

      // Check for ConjunctionMark structure
      var marks = ambig.allPaths().first;
      expect(marks.any((m) => m is ConjunctionMark), isTrue);
    });

    test("Predicate lookahead consistency", () {
      // S -> &'a' 'a'
      var g = Grammar(() => Rule("S", () => Token.char("a").and() >> Token.char("a")));
      verifyConsistency(g, "a");
    });

    test("Nested conjunction ambiguity", () {
      // S -> (A | B) && (C | D) where all are 'a'
      var g = Grammar(() {
        var a = Rule("A", () => Marker("A") >> Token.char("a"));
        var b = Rule("B", () => Marker("B") >> Token.char("a"));
        var c = Rule("C", () => Marker("C") >> Token.char("a"));
        var d = Rule("D", () => Marker("D") >> Token.char("a"));
        return Rule("S", () => (a() | b()) & (c() | d()));
      });

      var parser = SMParserMini(g);
      var ambig = (parser.parseAmbiguous("a") as ParseAmbiguousSuccess).forest;

      // Combinations: (A,C), (A,D), (B,C), (B,D)
      // Total 4 paths.
      var paths = ambig.allPaths().toList();
      expect(
        paths.length,
        4,
        reason: "Expected 4 paths for intersection of two binary choices with distinct markers.",
      );

      verifyConsistency(g, "a", isAmbiguous: true);
    });

    test("Mini Meta-Grammar snippet consistency", () {
      // file = rule | file rule
      // rule = name '=' body
      var g = Grammar(() {
        late Rule file;
        late Rule rule;
        var name = Rule("name", () => Token.charRange("a", "z").plus());
        var body = Rule("body", () => Token.charRange("0", "9").plus());
        rule = Rule(
          "rule",
          () => Label("name", name()) >> Token.char("=") >> Label("body", body()),
        );
        file = Rule("file", () => (Label("left", file()) >> Label("right", rule())) / rule());
        return file;
      });

      verifyConsistency(g, "a=1");
      verifyConsistency(g, "a=1b=2", isAmbiguous: true); // file rule or file(rule) rule?
      // Actually with recursion it's typically (file rule).
    });
  });
}
