// ignore_for_file: unreachable_from_main

import "dart:io";
import "dart:math" show max;
import "package:glush/glush.dart";

extension ShowErrors on ParseError {
  void displayError(String input) {
    List<String> inputRows = input.replaceAll("\r", "").split("\n");

    /// Surely the string we're trying to parse is not empty.
    if (inputRows.isEmpty) {
      throw StateError("Huh?");
    }

    int row = input.substring(0, position).split("\n").length;
    int column =
        input //
            .substring(0, position)
            .split("\n")
            .last
            .codeUnits
            .length +
        1;
    List<(int, String)> displayedRows = inputRows.indexed.toList().sublist(max(row - 3, 0), row);

    int longest = displayedRows.map((e) => e.$1.toString().length).reduce(max);

    print("Parse error at: ($row:$column)");
    print(
      displayedRows
          .map(
            (v) =>
                " ${(v.$1 + 1).toString().padLeft(longest)} | "
                "${v.$2}",
          )
          .join("\n"),
    );
    print("${" " * " ${''.padLeft(longest)} | ".length}${' ' * (column - 1)}^");
  }
}

extension on Pattern {
  Pattern operator /(Pattern other) => Alt(this, Seq(not(), other));
}

void mathSimple() {
  var parser =
      r"""
        expr =
              $add expr _ '+' _ expr
            | $num [0-9]+

        _ = [ \t\n\r]*
      """
          .toSMParser();

  const input = "1 + 2 + 3";
  var ambiguousResult = parser.parseAmbiguous(input);
  var evaluator = Evaluator<String>({
    "add": (ctx) => "(${ctx.next()} + ${ctx.next()})",
    "num": (ctx) => ctx.span.trim(),
  });
  if (ambiguousResult is ParseAmbiguousForestSuccess) {
    for (var result in ambiguousResult.forest.allPaths()) {
      var tree = result.evaluateStructure();
      print(evaluator.evaluate(tree));
    }
  }
}

void ambiguous() {
  var parser =
      r"""
        S = $TWO S S
          | $ONE s
        s = 's';
      """
          .toSMParser();

  var evaluator = Evaluator<String>({
    "TWO": (ctx) => "(${ctx.next()}${ctx.next()})",
    "ONE": (ctx) => "s",
  });

  for (int length = 1; length <= 5; ++length) {
    var input = "s" * length;
    var result = parser.parseAmbiguous(input);
    if (result is! ParseAmbiguousForestSuccess) {
      print("Failed to parse $input!");
      continue;
    }

    print(length);
    print("=" * 30);
    for (var markList in result.forest.allPaths()) {
      var tree = markList.evaluateStructure();
      var evaluated = evaluator.evaluate(tree);
      print(evaluated);
    }
    print("");
  }
}

void orderedChoice() {
  var grammar = Grammar(() {
    late Rule ab;
    late Rule c;
    c = Rule("c", () => ab() >> Token.char("c"));
    ab = Rule("ab", () => (Pattern.string("abc")) / (Pattern.string("ab")) / Token.char("a"));

    return c;
  });
  var parser = SMParserMini(grammar);
  var result = parser.parseAmbiguous("abc");
  print(result);
  if (result case ParseAmbiguousForestSuccess result) {
    print(result.forest.allPaths().toList());
  }
}

void meta() {
  var grammar = GrammarFileCompiler(
    GrammarFileParser(r"""
        # ==========================
        #   Full Meta Grammar
        # ==========================
        full = $full start _ file:file _ eof

        file = $rules left:file _ right:rule
            | $first rule:rule

        # Allow trailing trivia after a rule body so line comments behave
        # like whitespace instead of becoming the next token stream.
        rule = $rule name:ident _ '=' _ body:choice _ ( ';' )?

        choice = $choice left:choice _ '|' _ right:seq
              | seq

        seq = $seq left:seq _ &isContinuation right:prefix
            | prefix

        prefix = $and '&' atom:rep
              | $not '!' atom:rep
              | rep

        rep = $rep atom:primary kind:repKind
            | primary

        repKind = $star '*'      | $plus '+'
                | $starBang "*!" | $plusBang "+!"
                | $question '?'

        primary = $group '(' _ inner:choice _ ')'
                | $label name:ident ':' atom:primary
                | $mark '$' name:ident
                | start
                | eof
                | $ref name:ident
                | $lit literal
                | $range charRange
                | $any '.'

        isContinuation = ident !(_ [=])
                       | literal
                       | charRange
                       | '['
                       | '('
                       | '.'
                       | '!'
                       | '&'

        # Terminals
        ident = [A-Za-z$_] [A-Za-z$_0-9]*
        literal = ['] (!['] .)* ['] | ["] (!["] .)* ["]
        charRange = '[' (!']' .)* ']'

        _ = $ws (plain_ws | comment | newline)*
        comment = '#' (!newline .)* (newline | eof)
        plain_ws = [ \t]+ ![ \t]
        newline = [\n\r]+ ![\n\r]
      """).parse(),
  ).compile(startRuleName: "full");

  var parser = SMParserMini(grammar);

  var evaluator = Evaluator<Object?>({
    "full": (ctx) => ctx<Object?>("file"),
    "rules": (ctx) => [...ctx<List<Object?>>("left"), ctx<Object?>("right")],
    "first": (ctx) => [ctx<Object?>("rule")],
    "rule": (ctx) => (ctx<String>("name"), ctx<Object?>("body")),
    "choice": (ctx) => ["|", ctx<Object?>("left"), ctx<Object?>("right")],
    "seq": (ctx) => ["seq", ctx<Object?>("left"), ctx<Object?>("right")],
    "conj": (ctx) => ["&", ctx<Object?>("left"), ctx<Object?>("right")],
    "and": (ctx) => ["&", ctx<Object?>("atom")],
    "not": (ctx) => ["!", ctx<Object?>("atom")],
    "rep": (ctx) => [ctx<String>("kind"), ctx<Object?>("atom")],
    "star": (ctx) => "*",
    "plus": (ctx) => "+",
    "starBang": (ctx) => "*!",
    "plusBang": (ctx) => "+!",
    "question": (ctx) => "?",
    "group": (ctx) => ctx<Object?>("inner"),
    "label": (ctx) => (ctx<String>("name"), ctx<Object?>("body")),
    "mark": (ctx) => '\$${ctx<String>('name')}',
    "ref": (ctx) => ["ref", ctx<String>("name")],
    "lit": (ctx) => ["lit", ctx.span],
    "range": (ctx) => ["range", ctx.span],
    "any": (ctx) => ".",
    "name": (ctx) => ["name", ctx.span],
    "ws": (ctx) => "WS: ${ctx.span}",
  });

  const input = r"""
abc = c | &d !(e*!)
xyz = $test 'foo' [a-z]
# hello there
one = S 's' | 's' # wat
# helo helo
""";

  switch (parser.parse("${input.trim()}\n")) {
    case ParseSuccess result:
      var output = "Evaluated Meta Grammar Paths:\n";
      var tree = result.result.rawMarks.evaluateStructure();
      File("marks.txt")
        ..createSync(recursive: true)
        ..writeAsStringSync(result.result.rawMarks.toString());
      var evaluated = evaluator.evaluate(tree);
      output += "$evaluated\n";
      File("meta_out.txt").writeAsStringSync(output);
      print(output);
      print("Output written to meta_out.txt");
    case ParseError error:
      error.displayError(input);
    case _:
      throw Error();
  }
}

void main() async {
  // mathSimple();
  // ambiguous();
  // orderedChoice();
  meta();
}
