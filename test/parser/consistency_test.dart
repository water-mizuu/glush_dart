import "package:glush/glush.dart";
import "package:test/test.dart";

/// Helper to verify that parse() results are consistent with parseAmbiguous().
void verifyConsistency(Grammar g, String input, {bool isAmbiguous = false}) {
  var parser = SMParser(g);
  var result = parser.parse(input);
  var ambigResult = parser.parseAmbiguous(input);

  expect(result, isA<ParseSuccess>(), reason: "Standard parse failed for input: $input");
  expect(
    ambigResult,
    isA<ParseAmbiguousSuccess>(),
    reason: "Ambiguous parse failed for input: $input",
  );

  var standardMarks = (result as ParseSuccess).rawMarks;
  var ambigForest = (ambigResult as ParseAmbiguousSuccess).forest;
  var ambigPaths = ambigForest.evaluate().allMarkPaths().toList();

  if (!isAmbiguous) {
    expect(
      ambigPaths.length,
      1,
      reason: "Expected exactly one path for non-ambiguous grammar: $input",
    );
  }

  // Verify that the standard result's marks are present in the ambiguous set.
  var found = false;
  var evaluatedStandard = standardMarks;

  for (var path in ambigPaths) {
    var evaluatedAmbig = path;
    if (_listEquals(evaluatedStandard, evaluatedAmbig)) {
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

bool _marksEqual(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  return left == right;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) {
    return false;
  }

  for (int i = 0; i < left.length; ++i) {
    if (!_marksEqual(left[i], right[i])) {
      return false;
    }
  }

  return true;
}

void main() {
  group("Parser Consistency (parse vs parseAmbiguous)", () {
    test("Linear grammar matching", () {
      var g = Grammar(() => Rule("S", () => Token.char("a") >> Token.char("b")));
      verifyConsistency(g, "ab");
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

    test("Predicate lookahead consistency", () {
      // S -> &'a' 'a'
      var g = Grammar(() => Rule("S", () => Token.char("a").and() >> Token.char("a")));
      verifyConsistency(g, "a");
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
        file = Rule("file", () => (Label("left", file()) >> Label("right", rule())) | rule());
        return file;
      });

      verifyConsistency(g, "a=1");
      verifyConsistency(g, "a=1b=2", isAmbiguous: true); // file rule or file(rule) rule?
      // Actually with recursion it's typically (file rule).
    });
  });
}
