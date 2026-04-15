import "package:glush/glush.dart";

void main() {
  print("=== Math Expression Grammar - All Iteration Methods ===\n");

  // Grammar with MARKERS for mark-based evaluation
  var markerGrammar = Grammar(() {
    late Rule expr;
    late Rule term;
    late Rule factor;

    expr = Rule("expr", () {
      return (Marker("add") >> (expr() >> Pattern.char("+") >> term())) |
          (Marker("sub") >> (expr() >> Pattern.char("-") >> term())) |
          term();
    });

    term = Rule("term", () {
      return (Marker("mul") >> (term() >> Pattern.char("*") >> factor())) |
          (Marker("div") >> (term() >> Pattern.char("/") >> factor())) |
          factor();
    });

    factor = Rule("factor", () {
      return (Pattern.char("(") >> expr() >> Pattern.char(")")) |
          (Marker("number") >> (Token(const RangeToken(48, 57)).plus()));
    });

    return expr;
  });

  // Grammar with SEMANTIC ACTIONS for action-based evaluation
  var actionGrammar = Grammar(() {
    late Rule expr;
    late Rule term;
    late Rule factor;

    expr = Rule("expr", () {
      return (expr() >> Pattern.char("+") >> term()).withAction((span, results) {
            if (results case [[num l, "+"], num r]) {
              return l + r;
            }
            throw Exception(results);
          }) |
          (expr() >> Pattern.char("-") >> term()).withAction((span, results) {
            if (results case [[num l, "-"], num r]) {
              return l - r;
            }
            throw Exception(results);
          }) |
          term();
    });

    term = Rule("term", () {
      return (term() >> Pattern.char("*") >> factor()).withAction((span, results) {
            if (results case [[num l, "*"], num r]) {
              return l * r;
            }
            throw Exception(results);
          }) |
          (term() >> Pattern.char("/") >> factor()).withAction((span, results) {
            if (results case [[num l, "/"], num r]) {
              return l / r;
            }
            throw Exception(results);
          }) |
          factor();
    });

    factor = Rule("factor", () {
      return (Pattern.char("(") >> expr() >> Pattern.char(")")).withAction((span, results) {
            if (results case [["(", num middle], ")"]) {
              return middle;
            }
            throw Exception(results);
          }) |
          Token.charRange("0", "9").plus().withAction((span, results) => num.parse(span));
    });

    return expr;
  });

  // Grammar with no actions / markers.
  var cleanGrammar = Grammar(() {
    late Rule expr;
    late Rule term;
    late Rule factor;

    expr = Rule("expr", () {
      return (expr() >> Pattern.char("+") >> term()) |
          (expr() >> Pattern.char("-") >> term()) |
          term();
    });

    term = Rule("term", () {
      return (term() >> Pattern.char("*") >> factor()) |
          (term() >> Pattern.char("/") >> factor()) |
          factor();
    });

    factor = Rule("factor", () {
      return (Pattern.char("(") >> expr() >> Pattern.char(")")) | Token.charRange("0", "9").plus();
    });

    return expr;
  });

  const input = "1+2*3+4";
  print('Input: "$input" (expected result: 1 + 2 * 3 + 4 = 11)\n');
  print("=" * 70 + "\n");

  // Method 1: parse() with marks
  print("Method 1: parse() -> returns marks");
  _methodParse(markerGrammar, input);

  // Method 2: enumerateAllParses()
  print("\n\nMethod 2: enumerateAllParses() -> returns parse trees");
  _methodEnumerateAllParses(actionGrammar, input);
  _methodEnumerateAllParses(markerGrammar, input);

  // Method 3: enumerateAllParsesWithResults()
  print("\n\nMethod 3: enumerateAllParsesWithResults() -> trees with values");
  _methodEnumerateAllParsesWithResults(actionGrammar, input);
  _methodEnumerateAllParsesWithResults(markerGrammar, input);
  _methodEnumerateAllParsesWithResults(cleanGrammar, input);
}

void _methodParse(GrammarInterface grammar, String input) {
  var parser = SMParser(grammar);
  var result = parser.parse(input);

  var evaluator = Evaluator<num>({
    "add": (ctx) => ctx.next() + ctx.next(),
    "sub": (ctx) => ctx.next() - ctx.next(),
    "mul": (ctx) => ctx.next() * ctx.next(),
    "div": (ctx) => ctx.next() / ctx.next(),
    "number": (ctx) => num.parse(ctx.span),
  });

  if (result is ParseSuccess) {
    print("Parse succeeded.");
    var tree = result.result.rawMarks.evaluateStructure(input);
    var value = evaluator.evaluate(tree);
    print("Evaluated result: $value");
  } else if (result is ParseError) {
    print("Parse failed at position ${result.position}");
  }
}

// ============================================================================
// METHOD 2: enumerateAllParses()
// ============================================================================
void _methodEnumerateAllParses(GrammarInterface grammar, String input) {
  // var parser = SMParser(grammar);
  // var parses = parser.parseAmbiguous(input).ambiguousSuccess()?.forest.toList() ?? [];

  // if (parses.isNotEmpty) {
  //   print("Total parse trees: ${parses.length}");
  //   for (var (i, parse) in parses.indexed) {
  //     print("  Parse ${i + 1}:");
  //     print("    Tree: ${parse.toTreeString(input)}");
  //     var value = parser.evaluateParseDerivation(parse, input);
  //     print("    Raw structure: $value");
  //   }
  // } else {
  //   print("No parses found.");
  // }
}

// ============================================================================
// METHOD 3: enumerateAllParsesWithResults()
// ============================================================================
void _methodEnumerateAllParsesWithResults(GrammarInterface grammar, String input) {
  // var parser = SMParser(grammar);
  // var parses = parser.enumerateAllParsesWithResults(input).toList();

  // if (parses.isNotEmpty) {
  //   print("Total parse trees: ${parses.length}");
  //   for (var (i, parse) in parses.indexed) {
  //     print("  Parse ${i + 1}:");
  //     print("    Result: ${parse.tree.toTreeString(input)}");
  //     var value = parse.value;
  //     print("    Evaluated result: $value");
  //   }
  // } else {
  //   print("No parses found.");
  // }
}
