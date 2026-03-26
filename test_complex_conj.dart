import "package:glush/glush.dart";

void main() {
  print("--- Test Complex Conjunction ---");
  var grammar = Grammar(() {
    var a = Pattern.string("a");
    var b = Pattern.string("b");

    // Complex case: (a b) & (a b)
    var seqAB1 = Rule("seqAB1", () => a >> b);
    var seqAB2 = Rule("seqAB2", () => a >> b);
    var conjSeq = Rule("conjSeq", () => seqAB1 & seqAB2);

    return Rule("test", () => conjSeq);
  });

  var parser = SMParser(grammar);
  var input = "ab";

  print("Recognize '$input': ${parser.recognize(input)}");

  try {
    var count = parser.countAllParses(input);
    print("Count parses '$input': $count");

    for (var d in parser.enumerateAllParses(input)) {
      print("Derivation: $d");
      var eval = parser.evaluateParseDerivation(d, input);
      print("Evaluated: $eval");
    }
  } on Object catch (e, stack) {
    print("Test failed: $e");
    print(stack);
  }

  print("\n--- Test Ambiguous Conjunction (a|a) & a ---");
  try {
    var grammar2 = Grammar(() {
      var a = Pattern.string("a");
      var ambA = Rule("ambA", () => a | a);
      var ambConj = Rule("ambConj", () => ambA & a);
      return Rule("test", () => ambConj);
    });
    var parser2 = SMParser(grammar2);
    var input2 = "a";
    print("Recognize '$input2': ${parser2.recognize(input2)}");
    print("Count parses '$input2': ${parser2.countAllParses(input2)}");
    for (var d in parser2.enumerateAllParses(input2)) {
      print("Derivation: $d");
      print("Evaluated: ${parser2.evaluateParseDerivation(d, input2)}");
    }
  } on Object catch (e, stack) {
    print("Ambiguity test failed: $e");
    print(stack);
  }
}
